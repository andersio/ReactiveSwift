//
//  Scheduler.swift
//  ReactiveCocoa
//
//  Created by Justin Spahr-Summers on 2014-06-02.
//  Copyright (c) 2014 GitHub. All rights reserved.
//

/// Represents a serial queue of work items.
public protocol Scheduler {
	/// Enqueues an action on the scheduler.
	///
	/// When the work is executed depends on the scheduler in use.
	///
	/// Optionally returns a disposable that can be used to cancel the work
	/// before it begins.
	func schedule(action: () -> ()) -> Disposable?
}

/// A particular kind of scheduler that supports enqueuing actions at future
/// dates.
public protocol DateScheduler: Scheduler {
	/// Schedules an action for execution at or after the given date.
	///
	/// Optionally returns a disposable that can be used to cancel the work
	/// before it begins.
	func scheduleAfter(date: NSDate, action: () -> ()) -> Disposable?

	/// Schedules a recurring action at the given interval, beginning at the
	/// given start time.
	///
	/// Optionally returns a disposable that can be used to cancel the work
	/// before it begins.
	func scheduleAfter(date: NSDate, repeatingEvery: NSTimeInterval, withLeeway: NSTimeInterval, action: () -> ()) -> Disposable?
}

/// A scheduler that performs all work synchronously.
public struct ImmediateScheduler: Scheduler {
	public func schedule(action: () -> ()) -> Disposable? {
		action()
		return nil
	}
}

/// A scheduler that performs all work on the main thread.
public struct MainScheduler: DateScheduler {
	private let innerScheduler = QueueScheduler(dispatch_get_main_queue())

	public func schedule(action: () -> ()) -> Disposable? {
		return innerScheduler.schedule(action)
	}

	public func scheduleAfter(date: NSDate, action: () -> ()) -> Disposable? {
		return innerScheduler.scheduleAfter(date, action: action)
	}

	public func scheduleAfter(date: NSDate, repeatingEvery: NSTimeInterval, withLeeway: NSTimeInterval, action: () -> ()) -> Disposable? {
		return innerScheduler.scheduleAfter(date, repeatingEvery: repeatingEvery, withLeeway: withLeeway, action: action)
	}
}

/// A scheduler backed by a serial GCD queue.
public struct QueueScheduler: DateScheduler {
	internal let queue = dispatch_queue_create("com.github.ReactiveCocoa.QueueScheduler", DISPATCH_QUEUE_SERIAL)

	/// Initializes a scheduler that will target the given queue with its work.
	///
	/// Even if the queue is concurrent, all work items enqueued with the
	/// QueueScheduler will be serial with respect to each other.
	public init(_ queue: dispatch_queue_t) {
		dispatch_set_target_queue(queue, queue)
	}
	
	/// Initializes a scheduler that will target the global queue with the given
	/// priority.
	public init(_ priority: CLong) {
		self.init(dispatch_get_global_queue(priority, 0))
	}
	
	/// Initializes a scheduler that will target the default priority global
	/// queue.
	public init() {
		self.init(DISPATCH_QUEUE_PRIORITY_DEFAULT)
	}
	
	public func schedule(action: () -> ()) -> Disposable? {
		let d = SimpleDisposable()
	
		dispatch_async(queue, {
			if !d.disposed {
				action()
			}
		})
		
		return d
	}

	private func wallTimeWithDate(date: NSDate) -> dispatch_time_t {
		var seconds = 0.0
		let frac = modf(date.timeIntervalSince1970, &seconds)
		
		let nsec: Double = frac * Double(NSEC_PER_SEC)
		var walltime = timespec(tv_sec: CLong(seconds), tv_nsec: CLong(nsec))
		
		return dispatch_walltime(&walltime, 0)
	}

	public func scheduleAfter(date: NSDate, action: () -> ()) -> Disposable? {
		let d = SimpleDisposable()

		dispatch_after(wallTimeWithDate(date), queue, {
			if !d.disposed {
				action()
			}
		})

		return d
	}

	public func scheduleAfter(date: NSDate, repeatingEvery: NSTimeInterval, withLeeway leeway: NSTimeInterval, action: () -> ()) -> Disposable? {
		let nsecInterval = repeatingEvery * Double(NSEC_PER_SEC)
		let nsecLeeway = leeway * Double(NSEC_PER_SEC)
		
		let timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue)
		dispatch_source_set_timer(timer, wallTimeWithDate(date), UInt64(nsecInterval), UInt64(nsecLeeway))
		dispatch_source_set_event_handler(timer, action)
		dispatch_resume(timer)

		return ActionDisposable {
			dispatch_source_cancel(timer)
		}
	}
}

/// A scheduler that implements virtualized time, for use in testing.
public final class TestScheduler: DateScheduler {
	private final class ScheduledAction {
		let date: NSDate
		let action: () -> ()

		init(date: NSDate, action: () -> ()) {
			self.date = date
			self.action = action
		}

		func less(rhs: ScheduledAction) -> Bool {
			return date.compare(rhs.date) == NSComparisonResult.OrderedAscending
		}
	}

	private let lock = NSRecursiveLock()
	private var _currentDate: NSDate

	/// The virtual date that the scheduler is currently at.
	public var currentDate: NSDate {
		var d: NSDate? = nil

		lock.lock()
		d = _currentDate
		lock.unlock()

		return d!
	}

	private var scheduledActions: [ScheduledAction] = []

	/// Initializes a TestScheduler with the given start date.
	public init(startDate: NSDate = NSDate(timeIntervalSinceReferenceDate: 0)) {
		lock.name = "com.github.ReactiveCocoa.TestScheduler"
		_currentDate = startDate
	}

	private func schedule(action: ScheduledAction) -> Disposable {
		lock.lock()
		scheduledActions.append(action)
		scheduledActions.sort { $0.less($1) }
		lock.unlock()

		return ActionDisposable {
			self.lock.lock()
			self.scheduledActions = self.scheduledActions.filter { $0 !== action }
			self.lock.unlock()
		}
	}

	public func schedule(action: () -> ()) -> Disposable? {
		return schedule(ScheduledAction(date: currentDate, action: action))
	}

	public func scheduleAfter(date: NSDate, action: () -> ()) -> Disposable? {
		return schedule(ScheduledAction(date: date, action: action))
	}

	private func scheduleAfter(date: NSDate, repeatingEvery: NSTimeInterval, disposable: SerialDisposable, action: () -> ()) {
		disposable.innerDisposable = scheduleAfter(date) { [unowned self] in
			action()
			self.scheduleAfter(date.dateByAddingTimeInterval(repeatingEvery), repeatingEvery: repeatingEvery, disposable: disposable, action: action)
		}
	}

	public func scheduleAfter(date: NSDate, repeatingEvery: NSTimeInterval, withLeeway: NSTimeInterval, action: () -> ()) -> Disposable? {
		let disposable = SerialDisposable()
		scheduleAfter(date, repeatingEvery: repeatingEvery, disposable: disposable, action: action)
		return disposable
	}

	/// Advances the virtualized clock by the given interval, dequeuing and
	/// executing any actions along the way.
	public func advanceByInterval(interval: NSTimeInterval) {
		lock.lock()
		advanceToDate(currentDate.dateByAddingTimeInterval(interval))
		lock.unlock()
	}

	/// Advances the virtualized clock to the given future date, dequeuing and
	/// executing any actions up until that point.
	public func advanceToDate(newDate: NSDate) {
		lock.lock()

		assert(currentDate.compare(newDate) != NSComparisonResult.OrderedDescending)
		_currentDate = newDate
			
		while scheduledActions.count > 0 {
			if newDate.compare(scheduledActions[0].date) == NSComparisonResult.OrderedAscending {
				break
			}

			let scheduledAction = scheduledActions[0]
			scheduledActions.removeAtIndex(0)
			scheduledAction.action()
		}

		lock.unlock()
	}

	/// Dequeues and executes all scheduled actions, leaving the scheduler's
	/// date at `NSDate.distantFuture()`.
	public func run() {
		advanceToDate(NSDate.distantFuture() as NSDate)
	}
}
