# beacon_chain
# Copyright (c) 2021-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  stew/shims/[sets, hashes], chronicles,
  ../spec/forks

from ../spec/validator import compute_subscribed_subnets
from ../consensus_object_pools/block_pools_types import ShufflingRef
from ../consensus_object_pools/spec_cache import
  epoch, get_committee_assignments

export forks, tables, sets

const
  SUBNET_SUBSCRIPTION_LEAD_TIME_SLOTS* = 4
    ## The number of slots before we're up for aggregation duty that we'll
    ## actually subscribe to the subnet we're aggregating for - this gives
    ## the node time to find a mesh etc - can likely be further trimmed
  KNOWN_VALIDATOR_DECAY* = 3 * SLOTS_PER_EPOCH
    ## The number of slots before we "forget" about validators that have
    ## registered for duties - once we've forgotten about a validator, we'll
    ## eventually decrease the number of stability subnets we're subscribed to.
    ## Active validators are expected to register for duty every epoch - we use
    ## 3 epochs here to counter rounding errors and communication delays.
    ## When known validators decrease, we will keep the stability subnet around
    ## until it "naturally" expires.

type
  AggregatorDuty* = object
    subnet_id*: SubnetId
    slot*: Slot

  ActionTracker* = object
    nodeId: UInt256

    subscribeAllAttnets: bool

    currentSlot: Slot
      ## Duties that we accept are limited to a range around the current slot

    subscribedSubnets*: AttnetBits
      ## All subnets we're currently subscribed to

    nextCycleEpoch: Epoch

    # Used to track the next attestation and proposal slots using an
    # epoch-relative coordinate system. Doesn't need initialization.
    attestingSlots: array[2, uint32]
    proposingSlots: array[2, uint32]
    lastCalculatedEpoch*: Epoch

    attesterDepRoot*: Eth2Digest
      ## The latest dependent root we used to compute attestation duties
      ## for internal validators

    knownValidators*: Table[ValidatorIndex, Slot]
      ## Validators that we've recently seen - we'll subscribe to one stability
      ## subnet for each such validator - the slot is used to expire validators
      ## that no longer are posting duties

    duties: HashSet[AggregatorDuty]
      ## Known aggregation duties in the near future - before each such
      ## duty, we'll subscribe to the corresponding subnet to collect
      ## attestations for the aggregate

    lastSyncUpdate*: Opt[SyncCommitteePeriod]
    syncDuties*: Table[ValidatorPubKey, Epoch]

func hash*(x: AggregatorDuty): Hash =
  hashAllFields(x)

proc registerDuty*(
    tracker: var ActionTracker, slot: Slot, subnet_id: SubnetId,
    vidx: ValidatorIndex, isAggregator: bool) =
  # Only register relevant duties
  if slot < tracker.currentSlot or
      slot + (SLOTS_PER_EPOCH * 2) <= tracker.currentSlot:
    debug "Irrelevant duty", slot, subnet_id, vidx
    return

  tracker.knownValidators[vidx] = slot # Update validator last-seen registry

  if isAggregator:
    let newDuty = AggregatorDuty(slot: slot, subnet_id: subnet_id)

    if newDuty in tracker.duties:
      return

    debug "Registering aggregation duty", slot, subnet_id, vidx
    tracker.duties.incl(newDuty)

proc registerSyncDuty*(
    tracker: var ActionTracker, pubkey: ValidatorPubKey, until_epoch: Epoch) =
  if tracker.currentSlot.epoch >= until_epoch:
    return

  tracker.syncDuties.withValue(pubkey, entry) do:
    if entry[] < until_epoch:
      debug "Updating sync duty",
        pubkey = shortLog(pubkey), prev_until_epoch = entry[], until_epoch
      entry[] = until_epoch
      reset(tracker.lastSyncUpdate)
  do:
    debug "Registering sync duty", pubkey = shortLog(pubkey), until_epoch
    tracker.syncDuties[pubkey] = until_epoch
    reset(tracker.lastSyncUpdate)

proc hasSyncDuty*(
    tracker: ActionTracker, pubkey: ValidatorPubKey, epoch: Epoch): bool =
  epoch < tracker.syncDuties.getOrDefault(pubkey, GENESIS_EPOCH)

func aggregateSubnets*(tracker: ActionTracker, wallSlot: Slot): AttnetBits =
  var res: AttnetBits
  # Subscribe to subnets for upcoming duties
  for duty in tracker.duties:
    if wallSlot <= duty.slot and
        wallSlot + SUBNET_SUBSCRIPTION_LEAD_TIME_SLOTS > duty.slot:

      res[duty.subnet_id.int] = true
  res

# TODO https://github.com/nim-lang/Nim/issues/12172 keeps from stabilitySubnets
const allSubnetBits = block:
  var res: AttnetBits
  for i in 0..<res.len: res[i] = true
  res

func stabilitySubnets*(tracker: ActionTracker, slot: Slot): AttnetBits =
  if tracker.subscribeAllAttnets:
    allSubnetBits
  else:
    var res: AttnetBits
    if tracker.knownValidators.len > 0:
      for subnetId in compute_subscribed_subnets(tracker.nodeId, slot.epoch):
        res[subnetId.int] = true
    res

proc updateSlot*(tracker: var ActionTracker, wallSlot: Slot) =
  # Prune duties from the past - this collection is kept small because there
  # are only so many slot/subnet combos - prune both internal and API-supplied
  # duties at the same time
  tracker.duties.keepItIf(it.slot >= wallSlot)

  block:
    var dels: seq[ValidatorPubKey]
    for k, v in tracker.syncDuties:
      if wallSlot.epoch >= v:
        dels.add k
    for k in dels:
      tracker.syncDuties.del(k)

  var toPrune: seq[ValidatorIndex]
  for k, v in tracker.knownValidators:
    if v + KNOWN_VALIDATOR_DECAY < wallSlot: toPrune.add k
  for k in toPrune:
    debug "Validator no longer active", index = k
    tracker.knownValidators.del k

  tracker.currentSlot = wallSlot

func getNextValidatorAction(
    actionSlotSource: auto, lastCalculatedEpoch: Epoch, slot: Slot): Slot =
  # The relevant actions are in, depending on calculated bounds:
  # [aS[epoch mod 2], aS[1 - (epoch mod 2)]]
  #  current epoch          next epoch
  let orderedActionSlots = [
    actionSlotSource[     slot.epoch mod 2'u64],
    actionSlotSource[1 - (slot.epoch mod 2'u64)]]

  static: doAssert MIN_ATTESTATION_INCLUSION_DELAY == 1

  # Cleverer ways exist, but a short loop is fine. O(n) vs O(log n) isn't that
  # important when n is 32 or 64, with early exit on average no more than half
  # through.
  for i in [0'u64, 1'u64]:
    let bitmapEpoch = slot.epoch + i

    if bitmapEpoch > lastCalculatedEpoch:
      return FAR_FUTURE_SLOT

    for slotOffset in 0 ..< SLOTS_PER_EPOCH:
      let nextActionSlot = start_slot(bitmapEpoch) + slotOffset
      if ((orderedActionSlots[i] and (1'u32 shl slotOffset)) != 0) and
          nextActionSlot > slot:
        return nextActionSlot

  FAR_FUTURE_SLOT

func getNextAttestationSlot*(tracker: ActionTracker, slot: Slot): Slot =
  getNextValidatorAction(
    tracker.attestingSlots,
    tracker.lastCalculatedEpoch, slot)

func getNextProposalSlot*(tracker: ActionTracker, slot: Slot): Slot =
  getNextValidatorAction(
    tracker.proposingSlots,
    tracker.lastCalculatedEpoch, slot)

func needsUpdate*(
    tracker: ActionTracker, state: ForkyHashedBeaconState, epoch: Epoch): bool =
  # Using the attester dependent root here means we lock the action tracking to
  # the dependent root for attestation duties and not block proposal -
  # however, the risk of a proposer reordering in the last epoch is small
  # and the action tracker is speculative in nature.
  tracker.attesterDepRoot !=
    state.dependent_root(if epoch > Epoch(0): epoch - 1 else: epoch)

from std/sequtils import toSeq

func updateActions*(
    tracker: var ActionTracker, shufflingRef: ShufflingRef,
    beaconProposers: openArray[Opt[ValidatorIndex]]) =
  let epoch = shufflingRef.epoch

  # Updates the schedule for upcoming attestation and proposal work
  tracker.attesterDepRoot = shufflingRef.attester_dependent_root
  tracker.lastCalculatedEpoch = epoch

  let validatorIndices = toHashSet(toSeq(tracker.knownValidators.keys()))

  # Update proposals
  tracker.proposingSlots[epoch mod 2] = 0
  for i, proposer in beacon_proposers:
    if proposer.isSome and proposer.get() in validatorIndices:
      tracker.proposingSlots[epoch mod 2] =
        tracker.proposingSlots[epoch mod 2] or (1'u32 shl i)

  tracker.attestingSlots[epoch mod 2] = 0

  # The relevant bitmaps are 32 bits each.
  static: doAssert SLOTS_PER_EPOCH <= 32

  for (committeeIndex, subnet_id, slot) in
      get_committee_assignments(shufflingRef, validatorIndices):
    doAssert epoch(slot) == epoch

    # Each get_committee_assignments() call here is on the next epoch. At any
    # given time, only care about two epochs, the current and next epoch. So,
    # after it is done for an epoch, [aS[epoch mod 2], aS[1 - (epoch mod 2)]]
    # provides, sequentially, the current and next epochs' slot schedules. If
    # get_committee_assignments() has not been called for the next epoch yet,
    # typically because there hasn't been a block in the current epoch, there
    # isn't valid information in aS[1 - (epoch mod 2)], and only slots within
    # the current epoch can be known. Usually, this is not a major issue, but
    # when there hasn't been a block substantially through an epoch, it might
    # prove misleading to claim that there aren't attestations known, when it
    # only might be known either way for 3 more slots. However, it's also not
    # as important to attest if blocks aren't flowing as only attestations in
    # blocks garner rewards.
    tracker.attestingSlots[epoch mod 2] =
      tracker.attestingSlots[epoch mod 2] or
        (1'u32 shl (slot mod SLOTS_PER_EPOCH))

func init*(
    T: type ActionTracker, nodeId: UInt256, subscribeAllAttnets: bool): T =
  T(
    nodeId: nodeId,
    subscribeAllAttnets: subscribeAllAttnets,
  )
