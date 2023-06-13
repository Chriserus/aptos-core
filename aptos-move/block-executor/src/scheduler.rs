// Copyright © Aptos Foundation
// Parts of the project are originally copyright © Meta Platforms, Inc.
// SPDX-License-Identifier: Apache-2.0

use crate::{blockstm_providers::SchedulerProvider, counters::GET_NEXT_TASK_SECONDS};
use aptos_infallible::Mutex;
use aptos_mvhashmap::types::{Incarnation, TxnIndex, Version};
use crossbeam::utils::CachePadded;
use parking_lot::RwLockUpgradableReadGuard;
use std::{
    cmp::{max, min},
    hint,
    ops::DerefMut,
    sync::{
        atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering},
        Arc, Condvar,
    },
};

const TXN_IDX_MASK: u64 = (1 << 32) - 1;

pub type Wave = u32;

#[derive(Debug)]
pub enum DependencyStatus {
    // The dependency is not resolved yet.
    Unresolved,
    // The dependency is resolved.
    Resolved,
    // The parallel execution is halted.
    ExecutionHalted,
}
type DependencyCondvar = Arc<(Mutex<DependencyStatus>, Condvar)>;

// Return value of the function wait_for_dependency
pub enum DependencyResult {
    Dependency(DependencyCondvar),
    Resolved,
    ExecutionHalted,
}

/// A holder for potential task returned from the Scheduler. ExecutionTask and ValidationTask
/// each contain a version of transaction that must be executed or validated, respectively.
/// NoTask holds no task (similar None if we wrapped tasks in Option), and Done implies that
/// there are no more tasks and the scheduler is done.
#[derive(Debug)]
pub enum SchedulerTask {
    ExecutionTask(Version, Option<DependencyCondvar>),
    ValidationTask(Version, Wave),
    NoTask,
    Done,
}

/////////////////////////////// Explanation for ExecutionStatus ///////////////////////////////
/// All possible execution status for each transaction. In the explanation below, we abbreviate
/// 'execution status' as 'status'. Each status contains the latest incarnation number,
/// where incarnation = i means it is the i-th execution instance of the transaction.
///
/// 'ReadyToExecute' means that the corresponding incarnation should be executed and the scheduler
/// must eventually create a corresponding execution task. The scheduler ensures that exactly one
/// execution task gets created, changing the status to 'Executing' in the process. If a dependency
/// condition variable is set, then an execution of a prior incarnation is waiting on it with
/// a read dependency resolved (when dependency was encountered, the status changed to Suspended,
/// and suspended changed to ReadyToExecute when the dependency finished its execution). In this case
/// the caller need not create a new execution task, but just notify the suspended execution.
///
/// 'Executing' status of an incarnation turns into 'Executed' if the execution task finishes, or
/// if a dependency is encountered, it becomes 'ReadyToExecute(incarnation + 1)' once the
/// dependency is resolved. An 'Executed' status allows creation of validation tasks for the
/// corresponding incarnation, and a validation failure leads to an abort. The scheduler ensures
/// that there is exactly one abort, changing the status to 'Aborting' in the process. Once the
/// thread that successfully aborted performs everything that's required, it sets the status
/// to 'ReadyToExecute(incarnation + 1)', allowing the scheduler to create an execution
/// task for the next incarnation of the transaction.
///
/// 'ExecutionHalted' is a transaction status marking that parallel execution is halted, due to
/// reasons such as module r/w intersection or exceeding per-block gas limit. It is safe to ignore
/// this status during the transaction invariant checks, e.g., suspend(), resume(), set_executed_status().
/// When 'resolve_condvar' is called, all txns' statuses become ExecutionHalted.
///
/// Status transition diagram:
/// Ready(i)                                                                               ---
///    |  try_incarnate (incarnate successfully)                                             |
///    |                                                                                     |
///    ↓         suspend (waiting on dependency)                resume                       |
/// Executing(i) -----------------------------> Suspended(i) ------------> Ready(i)          |
///    |                                                                                     | resolve_condvar
///    |  finish_execution                                                                   |-----------------> ExecutionHalted
///    ↓                                                                                     |
/// Executed(i) (pending for (re)validations) ---------------------------> Committed(i)      |
///    |                                                                                     |
///    |  try_abort (abort successfully)                                                     |
///    ↓                finish_abort                                                         |
/// Aborting(i) ---------------------------------------------------------> Ready(i+1)      ---
///
#[derive(Debug)]
pub enum ExecutionStatus {
    ReadyToExecute(Incarnation, Option<DependencyCondvar>),
    Executing(Incarnation),
    Suspended(Incarnation, DependencyCondvar),
    Executed(Incarnation),
    Committed(Incarnation),
    Aborting(Incarnation),
    ExecutionHalted,
}

impl PartialEq for ExecutionStatus {
    fn eq(&self, other: &Self) -> bool {
        use ExecutionStatus::*;
        match (self, other) {
            (&ReadyToExecute(ref a, _), &ReadyToExecute(ref b, _))
            | (&Executing(ref a), &Executing(ref b))
            | (&Suspended(ref a, _), &Suspended(ref b, _))
            | (&Executed(ref a), &Executed(ref b))
            | (&Committed(ref a), &Committed(ref b))
            | (&Aborting(ref a), &Aborting(ref b)) => a == b,
            _ => false,
        }
    }
}

/////////////////////////////// Explanation for ValidationStatus ///////////////////////////////
/// All possible validation status for each transaction. In the explanation below, we abbreviate
/// 'validation status' as 'status'. Each status contains three wave numbers, each with different
/// meanings, but in general the concept of 'wave' keeps track of the version number of the validation.
///
/// 'max_triggered_wave' records the maximum wave that was triggered at the transaction index, and
/// will be incremented every time when the validation_idx is decreased. Initialized as 0.
///
/// 'maybe_max_validated_wave' records the maximum wave among successful validations of the corresponding
/// transaction, will be incremented upon successful validation (finish_validation). Initialized as None.
///
/// 'required_wave' in addition records the wave that must be successfully validated in order
/// for the transaction to be committed, required to handle the case of the optimization in
/// finish_execution when only the transaction itself is validated (if last incarnation
/// didn't write outside of the previous write-set). Initialized as 0.
///
/// Other than ValidationStatus, the 'wave' information is also recorded in 'validation_idx' and 'commit_state'.
/// Below is the description of the wave meanings and how they are updated. More details can be
/// found in the definition of 'validation_idx' and 'commit_state'.
///
/// In 'validation_idx', the first 32 bits identifies a validation wave while the last 32 bits
/// contain an index that tracks the minimum of all transaction indices that require validation.
/// The wave is incremented whenever the validation_idx is reduced due to transactions requiring
/// validation, in particular, after aborts and executions that write outside of the write set of
/// the same transaction's previous incarnation.
///
/// In 'commit_state', the first element records the next transaction to commit, and the
/// second element records the lower bound on the wave of a validation that must be successful
/// in order to commit the next transaction. The wave is updated in try_commit, upon seeing an
/// executed txn with higher max_triggered_wave. Note that the wave is *not* updated with the
/// required_wave of the txn that is being committed.
///
///
/////////////////////////////// Algorithm Description for Updating Waves ///////////////////////////////
/// In the following, 'update' means taking the maximum.
/// (1) Upon decreasing validation_idx, increment validation_idx.wave and update txn's
/// max_triggered_wave <- validation_idx.wave;
/// (2) Upon finishing execution of txn that is below validation_idx, update txn's
/// required_wave <- validation_idx.wave; (otherwise, the last triggered wave is below and will validate).
/// (3) Upon validating a txn successfully, update txn's maybe_max_validated_wave <- validation_idx.wave;
/// (4) Upon trying to commit an executed txn, update commit_state.wave <- txn's max_triggered_wave.
/// (5) If txn's maybe_max_validated_wave >= max(commit_state.wave, txn's required_wave), can commit the txn.
///
/// Remark: commit_state.wave is updated only with max_triggered_wave but not required_wave. This is
/// because max_triggered_wave implies that this wave of validations was required for all higher transactions
/// (and is set as a part of decrease_validation_idx), while required_wave is set for the transaction only
/// (when a validation task is returned to the caller). Moreover, the code is structured in a way that
/// decrease_validation_idx is always called for txn_idx + 1 (e.g. when aborting, there is no need to validate
/// the transaction before re-execution, and in finish_execution, even if there is a need to validate txn_idx,
/// it is returned to the caller directly, which is done so as an optimization and also for uniformity).
#[derive(Debug)]
pub struct ValidationStatus {
    max_triggered_wave: Wave,
    required_wave: Wave,
    maybe_max_validated_wave: Option<Wave>,
}

impl ValidationStatus {
    pub fn new() -> Self {
        ValidationStatus {
            max_triggered_wave: 0,
            required_wave: 0,
            maybe_max_validated_wave: None,
        }
    }
}

impl Default for ValidationStatus {
    fn default() -> Self {
        Self::new()
    }
}

pub struct Scheduler<P: SchedulerProvider> {
    provider: Arc<P>,

    /// An index i maps to indices of other transactions that depend on transaction i, i.e. they
    /// should be re-executed once transaction i's next incarnation finishes.
    txn_dependency: P::TxnDependencyCollection,

    /// An index i maps to the most up-to-date status of transaction i.
    txn_status: P::TxnStatusCollection,

    /// Next transaction to commit, and sweeping lower bound on the wave of a validation that must
    /// be successful in order to commit the next transaction.
    commit_state: CachePadded<Mutex<(TxnIndex, Wave)>>,

    // Note: with each thread reading both counters when deciding the next task, and being able
    // to choose either execution or validation task, separately padding these indices may increase
    // (real) cache invalidation traffic more than combat false sharing. Hence, currently we
    // don't pad separately, but instead put them in between two padded members (same cache line).
    // TODO: investigate the trade-off. Re-consider if we change task assignment logic (i.e. make
    // validation/execution preferences stick to the worker threads).
    /// A shared index that tracks the minimum of all transaction indices that require execution.
    /// The threads increment the index and attempt to create an execution task for the corresponding
    /// transaction, if the status of the txn is 'ReadyToExecute'. This implements a counting-based
    /// concurrent ordered set. It is reduced as necessary when transactions become ready to be
    /// executed, in particular, when execution finishes and dependencies are resolved.
    execution_idx: AtomicU32,
    /// The first 32 bits identifies a validation wave while the last 32 bits contain an index
    /// that tracks the minimum of all transaction indices that require validation.
    /// The threads increment this index and attempt to create a validation task for the
    /// corresponding transaction (if the status of the txn is 'Executed'), associated with the
    /// observed wave in the first 32 bits. Each validation wave represents the sequence of
    /// validations that must happen due to the fixed serialization order of transactions.
    /// The index is reduced as necessary when transactions require validation, in particular,
    /// after aborts and executions that write outside of the write set of the same transaction's
    /// previous incarnation. This also creates a new wave of validations, identified by the
    /// monotonically increasing index stored in the first 32 bits.
    validation_idx: AtomicU64,

    /// Shared marker that is set when a thread detects that all txns can be committed.
    done_marker: CachePadded<AtomicBool>,
}

/// Public Interfaces for the Scheduler
impl<P: SchedulerProvider> Scheduler<P> {
    pub fn new(provider: Arc<P>) -> Self {
        let initial_execution_idx = provider.get_first_tid();
        let txn_dependency = provider.new_txn_dep_info();
        let txn_status = provider.new_txn_status_provider();
        Self {
            provider,
            txn_dependency,
            txn_status,
            commit_state: CachePadded::new(Mutex::new((initial_execution_idx, 0))),
            execution_idx: AtomicU32::new(initial_execution_idx),
            validation_idx: AtomicU64::new(initial_execution_idx as u64),
            done_marker: CachePadded::new(AtomicBool::new(false)),
        }
    }

    /// If successful, returns Some(TxnIndex), the index of committed transaction.
    /// The current implementation has one dedicated thread to try_commit.
    /// Should not be called after the last transaction is committed.
    pub fn try_commit(&self) -> Option<TxnIndex> {
        let mut commit_state_mutex = self.commit_state.lock();
        let commit_state = commit_state_mutex.deref_mut();
        let (commit_idx, commit_wave) = (&mut commit_state.0, &mut commit_state.1);

        if let Some(validation_status) = P::get_txn_status_by_tid(&self.txn_status, *commit_idx)
            .1
            .try_read()
        {
            // Acquired the validation status read lock.
            if let Some(status) = P::get_txn_status_by_tid(&self.txn_status, *commit_idx)
                .0
                .try_upgradable_read()
            {
                // Acquired the execution status read lock, which can be upgrade to write lock if necessary.
                if let ExecutionStatus::Executed(incarnation) = *status {
                    // Status is executed and we are holding the lock.

                    // Note we update the wave inside commit_state only with max_triggered_wave,
                    // since max_triggered_wave records the new wave when validation index is
                    // decreased thus affecting all later txns as well,
                    // while required_wave only records the new wave for one single txn.
                    *commit_wave = max(*commit_wave, validation_status.max_triggered_wave);
                    if let Some(validated_wave) = validation_status.maybe_max_validated_wave {
                        if validated_wave >= max(*commit_wave, validation_status.required_wave) {
                            let mut status_write = RwLockUpgradableReadGuard::upgrade(status);
                            // Upgrade the execution status read lock to write lock.
                            // Can commit.
                            *status_write = ExecutionStatus::Committed(incarnation);

                            let cur_txn_idx = *commit_idx;
                            *commit_idx = self.provider.txn_index_right_after(*commit_idx);
                            if *commit_idx >= self.provider.txn_end_index() {
                                // All txns have been committed, the parallel execution can finish.
                                self.done_marker.store(true, Ordering::SeqCst);
                            }
                            return Some(cur_txn_idx);
                        }
                    }
                }
            }
        }
        None
    }

    #[cfg(test)]
    /// Return the TxnIndex and Wave of current commit index
    pub fn commit_state(&self) -> (TxnIndex, u32) {
        let commit_state = self.commit_state.lock();
        (commit_state.0, commit_state.1)
    }

    /// Try to abort version = (txn_idx, incarnation), called upon validation failure.
    /// When the invocation manages to update the status of the transaction, it changes
    /// Executed(incarnation) => Aborting(incarnation), it returns true. Otherwise,
    /// returns false. Since incarnation numbers never decrease, this also ensures
    /// that the same version may not successfully abort more than once.
    pub fn try_abort(&self, txn_idx: TxnIndex, incarnation: Incarnation) -> bool {
        // lock the execution status.
        // Note: we could upgradable read, then upgrade and write. Similar for other places.
        // However, it is likely an overkill (and overhead to actually upgrade),
        // while unlikely there would be much contention on a specific index lock.
        let status_ref = P::get_txn_status_by_tid(&self.txn_status, txn_idx);
        let mut status = status_ref.0.write();

        if *status == ExecutionStatus::Executed(incarnation) {
            *status = ExecutionStatus::Aborting(incarnation);
            true
        } else {
            false
        }
    }

    /// Return the next task for the thread.
    pub fn next_task(&self, committing: bool) -> SchedulerTask {
        let _timer = GET_NEXT_TASK_SECONDS.start_timer();
        loop {
            if self.done() {
                // No more tasks.
                return SchedulerTask::Done;
            }

            let (idx_to_validate, wave) =
                Self::unpack_validation_idx(self.validation_idx.load(Ordering::Acquire));
            let idx_to_execute = self.execution_idx.load(Ordering::Acquire);

            let prefer_validate = idx_to_validate
                < min(idx_to_execute, self.provider.txn_end_index())
                && !self.never_executed(idx_to_validate);

            if !prefer_validate && idx_to_execute >= self.provider.txn_end_index() {
                return if self.done() {
                    // Check again to avoid commit delay due to a race.
                    SchedulerTask::Done
                } else {
                    if !committing {
                        // Avoid pointlessly spinning, and give priority to other threads
                        // that may be working to finish the remaining tasks.
                        // We don't want to hint on the thread that is committing
                        // because it may have work to do (to commit) even if there
                        // is no more conventional (validation and execution tasks) work.
                        hint::spin_loop();
                    }
                    SchedulerTask::NoTask
                };
            }

            if prefer_validate {
                if let Some((version_to_validate, wave)) =
                    self.try_validate_next_version(idx_to_validate, wave)
                {
                    return SchedulerTask::ValidationTask(version_to_validate, wave);
                }
            } else if let Some((version_to_execute, maybe_condvar)) =
                self.try_execute_next_version()
            {
                return SchedulerTask::ExecutionTask(version_to_execute, maybe_condvar);
            }
        }
    }

    /// When a txn depends on another txn, adds it to the dependency list of the other txn.
    /// Returns true if successful, or false, if the dependency got resolved in the meantime.
    /// If true is returned, Scheduler guarantees that later (dep_txn_idx will finish execution)
    /// transaction txn_idx will be resumed, and corresponding execution task created.
    /// If false is returned, it is caller's responsibility to repeat the read that caused the
    /// dependency and continue the ongoing execution of txn_idx.
    pub fn wait_for_dependency(
        &self,
        txn_idx: TxnIndex,
        dep_txn_idx: TxnIndex,
    ) -> DependencyResult {
        // Note: Could pre-check that txn dep_txn_idx isn't in an executed state, but the caller
        // usually has just observed the read dependency.

        // Create a condition variable associated with the dependency.
        let dep_condvar = Arc::new((Mutex::new(DependencyStatus::Unresolved), Condvar::new()));

        let stored_deps_ref = P::get_txn_deps_by_tid(&self.txn_dependency, dep_txn_idx);
        let mut stored_deps = stored_deps_ref.lock();

        // Note: is_executed & suspend calls acquire (a different, status) mutex, while holding
        // (dependency) mutex. This is the only place in scheduler where a thread may hold > 1
        // mutexes. Thus, acquisitions always happen in the same order (here), may not deadlock.

        if self.is_executed(dep_txn_idx, true).is_some() {
            // Current status of dep_txn_idx is 'executed', so the dependency got resolved.
            // To avoid zombie dependency (and losing liveness), must return here and
            // not add a (stale) dependency.

            // Note: acquires (a different, status) mutex, while holding (dependency) mutex.
            // Only place in scheduler where a thread may hold >1 mutexes, hence, such
            // acquisitions always happens in the same order (this function), may not deadlock.
            return DependencyResult::Resolved;
        }

        // If the execution is already halted, suspend will return false.
        // The synchronization is guaranteed by the Mutex around txn_status.
        // If the execution is halted, the first finishing thread will first set the status of each txn
        // to be ExecutionHalted, then notify the conditional variable. So if a thread sees ExecutionHalted,
        // it knows the execution is halted and it can return; otherwise, the finishing thread will notify
        // the conditional variable later and awake the pending thread.
        if !self.suspend(txn_idx, dep_condvar.clone()) {
            return DependencyResult::ExecutionHalted;
        }

        // Safe to add dependency here (still holding the lock) - finish_execution of txn
        // dep_txn_idx is guaranteed to acquire the same lock later and clear the dependency.
        stored_deps.push(txn_idx);

        // Stored deps gets unlocked here.

        DependencyResult::Dependency(dep_condvar)
    }

    pub fn finish_validation(&self, txn_idx: TxnIndex, wave: Wave) {
        let validation_status_ref = P::get_txn_status_by_tid(&self.txn_status, txn_idx);
        let mut validation_status = validation_status_ref.1.write();
        validation_status.maybe_max_validated_wave = Some(
            validation_status
                .maybe_max_validated_wave
                .map_or(wave, |prev_wave| max(prev_wave, wave)),
        );
    }

    /// After txn is executed, schedule its dependencies for re-execution.
    /// If revalidate_suffix is true, decrease validation_idx to schedule all higher transactions
    /// for (re-)validation. Otherwise, in some cases (if validation_idx not already lower),
    /// return a validation task of the transaction to the caller (otherwise NoTask).
    pub fn finish_execution(
        &self,
        txn_idx: TxnIndex,
        incarnation: Incarnation,
        revalidate_suffix: bool,
    ) -> SchedulerTask {
        // Note: It is preferable to hold the validation lock throughout the finish_execution,
        // in particular before updating execution status. The point was that we don't want
        // any validation to come before the validation status is correspondingly updated.
        // It may be possible to make work more granular, but shouldn't make performance
        // difference and like this correctness argument is much easier to see, in fact also
        // the reason why we grab write lock directly, and never release it during the whole function.
        // So even validation status readers have to wait if they somehow end up at the same index.
        let validation_status_ref = P::get_txn_status_by_tid(&self.txn_status, txn_idx);
        let mut validation_status = validation_status_ref.1.write();
        self.set_executed_status(txn_idx, incarnation);

        let txn_deps: Vec<TxnIndex> = {
            let stored_deps_ref = P::get_txn_deps_by_tid(&self.txn_dependency, txn_idx);
            let mut stored_deps = stored_deps_ref.lock();
            // Holding the lock, take dependency vector.
            std::mem::take(&mut stored_deps)
        };

        // Mark dependencies as resolved and find the minimum index among them.
        let min_dep = txn_deps
            .into_iter()
            .map(|dep| {
                // Mark the status of dependencies as 'ReadyToExecute' since dependency on
                // transaction txn_idx is now resolved.
                self.resume(dep);

                dep
            })
            .min();
        if let Some(execution_target_idx) = min_dep {
            // Decrease the execution index as necessary to ensure resolved dependencies
            // get a chance to be re-executed.
            self.execution_idx
                .fetch_min(execution_target_idx, Ordering::SeqCst);
        }

        let (cur_val_idx, mut cur_wave) =
            Self::unpack_validation_idx(self.validation_idx.load(Ordering::Acquire));

        // If validation_idx is already lower than txn_idx, all required transactions will be
        // considered for validation, and there is nothing to do.
        if cur_val_idx > txn_idx {
            if revalidate_suffix {
                // The transaction execution required revalidating all higher txns (not
                // only itself), currently happens when incarnation writes to a new path
                // (w.r.t. the write-set of its previous completed incarnation).
                if let Some(wave) =
                    self.decrease_validation_idx(self.provider.txn_index_right_after(txn_idx))
                {
                    cur_wave = wave;
                };
            }
            // Update the minimum wave this txn needs to pass.
            validation_status.required_wave = cur_wave;
            return SchedulerTask::ValidationTask((txn_idx, incarnation), cur_wave);
        }

        SchedulerTask::NoTask
    }

    /// Finalize a validation task of version (txn_idx, incarnation). In some cases,
    /// may return a re-execution task back to the caller (otherwise, NoTask).
    pub fn finish_abort(&self, txn_idx: TxnIndex, incarnation: Incarnation) -> SchedulerTask {
        {
            // acquire exclusive lock on the validation status of txn_idx, and hold the lock
            // while calling decrease_validation_idx below. Otherwise, this thread might get
            // suspended after setting aborted ( = ready) status, and other threads might finish
            // re-executing, then commit txn_idx, and potentially commit txn_idx + 1 before
            // decrease_validation_idx would be able to set max_triggered_wave.
            //
            // Also, as a convention, we always acquire validation status lock before execution
            // status lock, as we have to have a consistent order and this order is easier to
            // provide correctness between finish_execution & try_commit.
            let validation_status_ref = P::get_txn_status_by_tid(&self.txn_status, txn_idx);
            let _validation_status = validation_status_ref.1.write();

            self.set_aborted_status(txn_idx, incarnation);

            // Schedule higher txns for validation, skipping txn_idx itself (needs to be
            // re-executed first).
            self.decrease_validation_idx(self.provider.txn_index_right_after(txn_idx));

            // can release the lock early.
        }

        // txn_idx must be re-executed, and if execution_idx is lower, it will be.
        if self.execution_idx.load(Ordering::Acquire) > txn_idx {
            // Optimization: execution_idx is higher than txn_idx, but decreasing it may
            // lead to wasted work for all indices between txn_idx and execution_idx.
            // Instead, attempt to create a new incarnation and return the corresponding
            // re-execution task back to the caller. If incarnation fails, there is
            // nothing to do, as another thread must have succeeded to incarnate and
            // obtain the task for re-execution.
            if let Some((new_incarnation, maybe_condvar)) = self.try_incarnate(txn_idx) {
                return SchedulerTask::ExecutionTask((txn_idx, new_incarnation), maybe_condvar);
            }
        }

        SchedulerTask::NoTask
    }

    /// This function can halt the BlockSTM early, even if there are unfinished tasks.
    /// It will set the done_marker to be true, resolve all pending dependencies.
    ///
    /// Currently there are 4 scenarios to early halt the BlockSTM execution.
    /// 1. There is a module publishing txn that has read/write intersection with any txns even during speculative execution.
    /// 2. There is a txn with VM execution status Abort.
    /// 3. There is a txn with VM execution status SkipRest.
    /// 4. The committed txns have exceeded the PER_BLOCK_GAS_LIMIT.
    ///
    /// For scenarios 1 and 2, only the error will be returned as the output of the block execution.
    /// For scenarios 3 and 4, the execution outputs of the committed txn prefix will be returned.
    pub fn halt(&self) {
        // The first thread that sets done_marker to be true will be reponsible for
        // resolving the conditional variables, to help other theads that may be pending
        // on the read dependency. See the comment of the function resolve_condvar().
        if !self.done_marker.swap(true, Ordering::SeqCst) {
            for txn_idx in self.provider.all_txn_indices() {
                self.resolve_condvar(txn_idx);
            }
        }
    }

    /// When early halt the BlockSTM, some of the threads
    /// may still be working on execution, and waiting for dependency (indicated by the condition variable `condvar`).
    /// Therefore the commit thread needs to wake up all such pending threads, by sending notification to the condition
    /// variable and setting the lock variables properly.
    pub fn resolve_condvar(&self, txn_idx: TxnIndex) {
        let status_ref = P::get_txn_status_by_tid(&self.txn_status, txn_idx);
        let mut status = status_ref.0.write();
        {
            // Only transactions with status Suspended or ReadyToExecute may have the condition variable of pending threads.
            match &*status {
                ExecutionStatus::Suspended(_, condvar)
                | ExecutionStatus::ReadyToExecute(_, Some(condvar)) => {
                    let (lock, cvar) = &*(condvar.clone());
                    // Mark parallel execution halted due to reasons like module r/w intersection.
                    *lock.lock() = DependencyStatus::ExecutionHalted;
                    // Wake up the process waiting for dependency.
                    cvar.notify_one();
                },
                _ => (),
            }
            // Set the all transactions' status to be ExecutionHalted.
            // Then any dependency read (wait_for_dependency) will immediately return and abort the VM execution.
            *status = ExecutionStatus::ExecutionHalted;
        }
    }
}

/// Private functions of the Scheduler
impl<P: SchedulerProvider> Scheduler<P> {
    fn unpack_validation_idx(validation_idx: u64) -> (TxnIndex, Wave) {
        (
            (validation_idx & TXN_IDX_MASK) as TxnIndex,
            (validation_idx >> 32) as Wave,
        )
    }

    /// Decreases the validation index, adjusting the wave and validation status as needed.
    fn decrease_validation_idx(&self, target_idx: TxnIndex) -> Option<Wave> {
        if target_idx >= self.provider.txn_end_index() {
            return None;
        }

        if let Ok(prev_val_idx) =
            self.validation_idx
                .fetch_update(Ordering::Acquire, Ordering::SeqCst, |val_idx| {
                    let (txn_idx, wave) = Self::unpack_validation_idx(val_idx);
                    if txn_idx > target_idx {
                        let validation_status_ref =
                            P::get_txn_status_by_tid(&self.txn_status, target_idx);
                        let mut validation_status = validation_status_ref.1.write();
                        // Update the minimum wave all the suffix txn needs to pass.
                        // We set it to max for safety (to avoid overwriting with lower values
                        // by a slower thread), but currently this isn't strictly required
                        // as all callers of decrease_validation_idx hold a write lock on the
                        // previous transaction's validation status.
                        validation_status.max_triggered_wave =
                            max(validation_status.max_triggered_wave, wave + 1);

                        // Pack into validation index.
                        Some((target_idx as u64) | ((wave as u64 + 1) << 32))
                    } else {
                        None
                    }
                })
        {
            let (_, wave) = Self::unpack_validation_idx(prev_val_idx);
            // Note that 'wave' is the previous wave value, and we must update it to 'wave + 1'.
            Some(wave + 1)
        } else {
            None
        }
    }

    /// Try and incarnate a transaction. Only possible when the status is
    /// ReadyToExecute(incarnation), in which case Some(incarnation) is returned and the
    /// status is (atomically, due to the mutex) updated to Executing(incarnation).
    /// An unsuccessful incarnation returns None. Since incarnation numbers never decrease
    /// for each transaction, incarnate function may not succeed more than once per version.
    fn try_incarnate(&self, txn_idx: TxnIndex) -> Option<(Incarnation, Option<DependencyCondvar>)> {
        if txn_idx >= self.provider.txn_end_index() {
            return None;
        }

        // Note: we could upgradable read, then upgrade and write. Similar for other places.
        // However, it is likely an overkill (and overhead to actually upgrade),
        // while unlikely there would be much contention on a specific index lock.
        let status_ref = P::get_txn_status_by_tid(&self.txn_status, txn_idx);
        let mut status = status_ref.0.write();
        if let ExecutionStatus::ReadyToExecute(incarnation, maybe_condvar) = &*status {
            let ret = (*incarnation, maybe_condvar.clone());
            *status = ExecutionStatus::Executing(*incarnation);
            Some(ret)
        } else {
            None
        }
    }

    /// If the status of transaction is Executed(incarnation), returns Some(incarnation),
    /// Useful to determine when a transaction can be validated, and to avoid a race in
    /// dependency resolution.
    /// If include_committed is true (which is when calling from wait_for_dependency),
    /// then committed transaction is also considered executed (for dependency resolution
    /// purposes). If include_committed is false (which is when calling from
    /// try_validate_next_version), then we are checking if a transaction may be validated,
    /// and a committed (in between) txn does not need to be scheduled for validation -
    /// so can return None.
    fn is_executed(&self, txn_idx: TxnIndex, include_committed: bool) -> Option<Incarnation> {
        debug_assert!(txn_idx < self.provider.txn_end_index());

        let status_ref = P::get_txn_status_by_tid(&self.txn_status, txn_idx);
        let status = status_ref.0.read();
        match *status {
            ExecutionStatus::Executed(incarnation) => Some(incarnation),
            ExecutionStatus::Committed(incarnation) => {
                if include_committed {
                    // Committed txns are also considered executed for dependency resolution purposes.
                    Some(incarnation)
                } else {
                    // Committed txns do not need to be scheduled for validation in try_validate_next_version.
                    None
                }
            },
            _ => None,
        }
    }

    /// Returns true iff no incarnation (even the 0-th one) has set the executed status, i.e.
    /// iff the execution status is READY_TO_EXECUTE/EXECUTING/SUSPENDED for incarnation 0.
    fn never_executed(&self, txn_idx: TxnIndex) -> bool {
        let status_ref = P::get_txn_status_by_tid(&self.txn_status, txn_idx);
        let status = status_ref.0.read();
        matches!(
            *status,
            ExecutionStatus::ReadyToExecute(0, _)
                | ExecutionStatus::Executing(0)
                | ExecutionStatus::Suspended(0, _)
        )
    }

    /// Grab an index to try and validate next (by fetch-and-incrementing validation_idx).
    /// - If the index is out of bounds, return None (and invoke a check of whethre
    /// all txns can be committed).
    /// - If the transaction is ready for validation (EXECUTED state), return the version
    /// to the caller.
    /// - Otherwise, return None.
    fn try_validate_next_version(
        &self,
        idx_to_validate: TxnIndex,
        wave: Wave,
    ) -> Option<(Version, Wave)> {
        // We do compare-and-swap here instead of fetch-and-increment as for execution index
        // because we would like to not validate transactions when lower indices are in the
        // 'never_executed' state (to avoid unnecessarily reducing validation index and creating
        // redundant validation tasks). This is checked in the caller (in 'next_task' function),
        // but if we used fetch-and-increment, two threads can arrive in a cloned state and
        // both increment, effectively skipping over the 'never_executed' transaction index.
        let validation_idx = (idx_to_validate as u64) | ((wave as u64) << 32);
        let new_validation_idx =
            (self.provider.txn_index_right_after(idx_to_validate) as u64) | ((wave as u64) << 32);
        if self
            .validation_idx
            .compare_exchange(
                validation_idx,
                new_validation_idx,
                Ordering::Acquire,
                Ordering::SeqCst,
            )
            .is_ok()
        {
            // Successfully claimed idx_to_validate to attempt validation.
            // If incarnation was last executed, and thus ready for validation,
            // return version and wave for validation task, otherwise None.
            return self
                .is_executed(idx_to_validate, false)
                .map(|incarnation| ((idx_to_validate, incarnation), wave));
        }

        None
    }

    /// Grab an index to try and execute next (by fetch-and-incrementing execution_idx).
    /// - If the index is out of bounds, return None (and invoke a check of whether
    /// all txns can be committed).
    /// - If the transaction is ready for execution (ReadyToExecute state), attempt
    /// to create the next incarnation (should happen exactly once), and if successful,
    /// return the version to the caller for the corresponding ExecutionTask.
    /// - Otherwise, return None.
    fn try_execute_next_version(&self) -> Option<(Version, Option<DependencyCondvar>)> {
        let idx_to_execute = self
            .execution_idx
            .fetch_update(Ordering::SeqCst, Ordering::SeqCst, |v| {
                Some(self.provider.txn_index_right_after(v))
            })
            .unwrap();

        if idx_to_execute >= self.provider.txn_end_index() {
            return None;
        }

        // If successfully incarnated (changed status from ready to executing),
        // return version for execution task, otherwise None.
        self.try_incarnate(idx_to_execute)
            .map(|(incarnation, maybe_condvar)| ((idx_to_execute, incarnation), maybe_condvar))
    }

    /// Put a transaction in a suspended state, with a condition variable that can be
    /// used to wake it up after the dependency is resolved.
    /// Return true when the txn is successfully suspended.
    /// Return false when the execution is halted.
    fn suspend(&self, txn_idx: TxnIndex, dep_condvar: DependencyCondvar) -> bool {
        let status_ref = P::get_txn_status_by_tid(&self.txn_status, txn_idx);
        let mut status = status_ref.0.write();

        match *status {
            ExecutionStatus::Executing(incarnation) => {
                *status = ExecutionStatus::Suspended(incarnation, dep_condvar);
                true
            },
            ExecutionStatus::ExecutionHalted => false,
            _ => unreachable!(),
        }
    }

    /// When a dependency is resolved, mark the transaction as ReadyToExecute with an
    /// incremented incarnation number.
    /// The caller must ensure that the transaction is in the Suspended state.
    fn resume(&self, txn_idx: TxnIndex) {
        let status_ref = P::get_txn_status_by_tid(&self.txn_status, txn_idx);
        let mut status = status_ref.0.write();

        if matches!(*status, ExecutionStatus::ExecutionHalted) {
            return;
        }

        if let ExecutionStatus::Suspended(incarnation, dep_condvar) = &*status {
            *status = ExecutionStatus::ReadyToExecute(*incarnation, Some(dep_condvar.clone()));
        } else {
            unreachable!();
        }
    }

    /// Set status of the transaction to Executed(incarnation).
    fn set_executed_status(&self, txn_idx: TxnIndex, incarnation: Incarnation) {
        let status_ref = P::get_txn_status_by_tid(&self.txn_status, txn_idx);
        let mut status = status_ref.0.write();
        // The execution is already halted.
        if matches!(*status, ExecutionStatus::ExecutionHalted) {
            return;
        }

        // Only makes sense when the current status is 'Executing'.
        debug_assert!(*status == ExecutionStatus::Executing(incarnation));
        *status = ExecutionStatus::Executed(incarnation);
    }

    /// After a successful abort, mark the transaction as ready for re-execution with
    /// an incremented incarnation number.
    fn set_aborted_status(&self, txn_idx: TxnIndex, incarnation: Incarnation) {
        let status_ref = P::get_txn_status_by_tid(&self.txn_status, txn_idx);
        let mut status = status_ref.0.write();
        // The execution is already halted.
        if matches!(*status, ExecutionStatus::ExecutionHalted) {
            return;
        }

        // Only makes sense when the current status is 'Aborting'.
        debug_assert!(*status == ExecutionStatus::Aborting(incarnation));
        *status = ExecutionStatus::ReadyToExecute(incarnation + 1, None);
    }

    /// Checks whether the done marker is set. The marker can only be set by 'try_commit'.
    fn done(&self) -> bool {
        self.done_marker.load(Ordering::Acquire)
    }
}
