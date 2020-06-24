//  FourFour.swift
//  Created by Ryan Cumley on 6/10/20.

import Combine

///Similar in most ways to `Element` in the Reactive Streams Specification, an `Event<T>` is the granular/discreet/individual package of data which is "streamed" through the components of a reactive system.
///
///While `Event<T>` is a value type, and allows us to realize the RSS's goal of a definitively sequencable series of events passed over asynchronous boundaries; `Event<T>` includes the ability to optionally attach the previously emitted value in the sequence along with the current one. This extra information can be useful in certain situations where the `difference` between current/previous is desired, but a subscriber does not wish to maintain state/history. For example, as a performance optimization where a subscriber only takes action when a value changes, and ignores the event if the new value is the same as the previous.
///
///Since this abstraction is still a singular value, we may still exercise all of our familiar Functional Programming toolkits to ensure that every Subscribing Component processes a `well-ordered` sequence of discreet events.
///
///However, a clever author could certainly compare what the publisher intended as `previous` with how the events actually arrived over the asynchronous boundary, and construct a valid alternate history/sequence/stream, allowing them to "break" the core abstraction of reactive programming: locally well-ordered sequences. In practice, this is unlikely to cause real problems.
struct Event<T> {
    let new: T
    let previous: T?
}

///Similar to PassthroughSubject and CurrentValueSubject, Signal<T> provides a bridge between the Imperative and Reactive worlds. The difference is where PassthroughSubject is ephemeral, and CurrentValueSubject is stateful with respect to a single value (ie. you can query CurrentValueSubject at any moment to learn the current 'state'), Signal remembers not just the current state, but the previous state as well, up to a time history depth of (t - 1)
///
///Signal<T> may be instantiated with no values, only a current value, or a current & a previous value. This allows flexibility for use in situations where sensible initial value(s) are or are not available.
///
///As a Publisher, Signal<T> will emit values every time `update(_ value)` is called, regardless of whether or not it was initialized with one or more values.
///
///Whether or not you think it's cheating to "remember" a portion of a stream's history (in this case merely the most recently emitted value alone), this abstraction still allows for Functional Programming purity, as the `Event<T>` emitted is a pure value type, eminently suitable for pure functional computation.
final class Signal<T>: Publisher {
    typealias Output = Event<T>
    typealias Failure = Never
    
    private var subscribers: Array<AnySubscriber<Event<T>, Never>> = []
    func receive<S>(subscriber: S) where S : Subscriber, Never == S.Failure, Event<T> == S.Input { subscribers.append(AnySubscriber(subscriber)) }
    
    fileprivate(set) var currentValue: T?
    fileprivate(set) var previousValue: T?
    func update(_ newValue: T) {
        let event = Event<T>(new: newValue, previous: currentValue)
        
        subscribers.enumerated().forEach{
            let demand = $0.element.receive(event)
            if demand == .none, demand.max == 0 {
                $0.element.receive(completion: .finished)
                subscribers.remove(at: $0.offset)
            }
        }
        
        self.previousValue = self.currentValue
        self.currentValue = newValue
    }
    
    init(current: T? = nil, previous: T? = nil) {
        self.currentValue = current
        self.previousValue = previous
    }
    
    
    
    deinit {
        subscribers.forEach{ $0.receive(completion: .finished) }
        subscribers = []
        observations.removeAll()
    }
    
    fileprivate var observations = Set<AnyCancellable>()
}

fileprivate final class MergeSignal<T,U>: Publisher, Subscriber {
    //Subscriber Conformance
    typealias Input = Event<U>
    func receive(completion: Subscribers.Completion<Never>) {
        //propagate a completion downstream?
    }
    
    func receive(_ input: Event<U>) -> Subscribers.Demand {
        //in the operator impl,
        
        return .unlimited
    }
    
    func receive(subscription: Subscription) {
            //I don't think there's any input or sanitization needed here.
    }

    //Publisher conformance
    typealias Output = Event<T>
    typealias Failure = Never

    private var subscribers: Array<AnySubscriber<Event<T>, Never>> = []
    func receive<S>(subscriber: S) where S : Subscriber, Never == S.Failure, Event<T> == S.Input { subscribers.append(AnySubscriber(subscriber)) }

    //So I can probably `private` hide all the internals here, because nobody outside this file is going to see or call thse things, And I can AnyPublisher erase my output
    private(set) var currentValue: T?
    private(set) var previousValue: T?

    //Can probably just directly invoke this on the subscription to the upstream model
    private func update(_ newValue: T) {
        let event = Event<T>(new: newValue, previous: currentValue)

        subscribers.enumerated().forEach{
            let demand = $0.element.receive(event)
            if demand == .none, demand.max == 0 {
                $0.element.receive(completion: .finished)
                subscribers.remove(at: $0.offset)
            }
        }

        self.previousValue = self.currentValue
        self.currentValue = newValue
    }

    
    //So we don't need to initialize off of values, we need to initialize somehow off type signatures and let the `<~>` operator do the work to plumb things together. And rememeber, the details of how we do this will all be here in this file and not visible to users of the framework.
    init(current: T? = nil, previous: T? = nil) {
        self.currentValue = current
        self.previousValue = previous
    }

    deinit {
        subscribers.forEach{ $0.receive(completion: .finished) }
        subscribers = []
        observations.removeAll()
    }

    fileprivate var observations = Set<AnyCancellable>()
}

///The foundational unit of composition for a reactive system, a `ReactiveComponent` defines & publishes a stream of `Event<Model>`'s; and optionally defines an upstream `Event<Model>` which it subscribes to, as well as how to react to publications of that upstream `Event<Model>`
///
///You may use ReactiveComponent as the beginning/origin of a stream by declaring `typealias UpstreamModel = ()`, which makes your component satisfy the "Publisher" component spec from RSS. If both `Model` and `UpstreamModel` are defined, then your component satisfies the `Processor` component spec from RSS, and can be thought of as fitting into the "Middle" of a stream.
protocol ReactiveComponent {
    associatedtype Model
    var state: Signal<Model> { get }
    
    associatedtype UpstreamModel
    func react(toNew: UpstreamModel)
    func react(toNew: UpstreamModel, withPrevious: UpstreamModel)
}

extension ReactiveComponent where UpstreamModel == () {
    func react(toNew: UpstreamModel) {}
    func react(toNew: UpstreamModel, withPrevious: UpstreamModel) {}
}

///ReactiveRenderers define the "end" of a stream, subscribing to an upstream publisher of `Event<Model>`'s, but do not publish an events of their own.
///
///Defining your component as a ReactiveRenderer satisfies the `Subscriber` component spec from RSS
protocol ReactiveRenderer {
    associatedtype UpstreamModel
    func react(toNew: UpstreamModel)
    func react(toNew: UpstreamModel, withPrevious: UpstreamModel)
}

precedencegroup ReactiveStreamPrecedence {
    lowerThan: TernaryPrecedence
    higherThan: AssignmentPrecedence
    associativity: left
    assignment: false
}

precedencegroup CombineReactiveStreamPrecedence {
    lowerThan: TernaryPrecedence
    higherThan: ReactiveStreamPrecedence
    associativity: left
    assignment: false
}

infix operator ~>>: ReactiveStreamPrecedence

///Join two reactive elements together
func ~>> <S: ReactiveComponent, C: ReactiveComponent>(lhs: S, rhs: C) -> Signal<C.Model> where S.Model == C.UpstreamModel {
    lhs.state.sink{ event in
        rhs.react(toNew: event.new)
        event.previous.flatMap{ rhs.react(toNew: event.new, withPrevious: $0) }
    }
    .store(in: &rhs.state.observations)
    
    return rhs.state
}

func ~>> <S,C: ReactiveComponent>(lhs: Signal<S>, rhs: C) -> Signal<C.Model> where S == C.UpstreamModel {
    lhs.sink{ event in
        rhs.react(toNew: event.new)
        event.previous.flatMap{ rhs.react(toNew: event.new, withPrevious: $0) }
    }
    .store(in: &rhs.state.observations)
    
    return rhs.state
}

func ~>> <S: ReactiveComponent, C: ReactiveRenderer>(lhs: S, rhs: C) -> C where S.Model == C.UpstreamModel {
    lhs.state.sink{ event in
        rhs.react(toNew: event.new)
        event.previous.flatMap{ rhs.react(toNew: event.new, withPrevious: $0) }
    }
    .store(in: &lhs.state.observations)
    
    return rhs
}

func ~>> <S,C: ReactiveRenderer>(lhs: Signal<S>, rhs: C) -> C where S == C.UpstreamModel {
    lhs.sink{ event in
        rhs.react(toNew: event.new)
        event.previous.flatMap{ rhs.react(toNew: event.new, withPrevious: $0) }
    }
    .store(in: &lhs.observations)
    
    return rhs
}

fileprivate struct MergeStreamComponent<U,D>: ReactiveComponent {
    typealias Model = D
    var state = Signal<D>()
    typealias UpstreamModel = U
    
    init(upstream: AnyPublisher<U,Never>, downstream: D.Type) {
        //Have to instantiante our downstream signal right here
    }
    
    
    func react(toNew: UpstreamModel) {
        
    }
    
    func react(toNew: UpstreamModel, withPrevious: UpstreamModel){
        
    }
}

infix operator <~>: CombineReactiveStreamPrecedence

func <~><J: ReactiveComponent, K: ReactiveComponent>(first: J, second: K) -> Signal<(J.Model?, K.Model?)> {
    let current = (first.state.currentValue, second.state.currentValue)
    let previous = (first.state.previousValue, second.state.previousValue)
    let signal = Signal<(J.Model?, K.Model?)>(current: current, previous: previous)
    
    // the ~>> operator erases stream pairings down to Signal<T>'s, so that's the raw input I'll expect to my operator
    //if I create the MergeSignal instance here and return it's Signal, we'll have no ARC owner; so... gotta solve that.
    
    
    //and now we need to CombineLatest to fire our new Signal
    //So if Signa<T> fileprivate conformed to Subscriber, could I upstream the newly created Signal instance here to just combineLatest?
    //Let's try it out!

    
    return signal
}

struct UserService: ReactiveComponent {
    typealias UpstreamModel = ()
    enum Model { case initial, data }
    var state = Signal<Model>()

}
struct SelectedRecipeService: ReactiveComponent {
    typealias UpstreamModel = ()
    enum Model { case initial, meat }
    var state = Signal<Model>()
}

struct CombinedStreams: ReactiveComponent {
    enum Model { case one }
    var state = Signal<Model>()
    typealias UpstreamModel = (UserService.Model?, SelectedRecipeService.Model?)
    
    func react(toNew: (UserService.Model?, SelectedRecipeService.Model?)) {
        switch toNew {
            
            //If you're sure that one of the `nil` states won't ever happen, you can just ignore that case/pattern match
            //So the practical implication of these optionals doesn't even need to be unwrapped directly, and you as an author have great freedom to write tersely if you like, or explicitly cover all possible upstream states.
            //That's probably reasonable to expect you to be aware of what's possible when combining upstream streams, so it's ok if we're assuming you'll be responsible here.
            
        case (.data, nil):
            
            break
            
        case (nil, nil):
            break
            
        case (nil, .meat):
            
            break
            
        default:
            break
        }
    }
    
    func react(toNew: (UserService.Model?, SelectedRecipeService.Model?), withPrevious: (UserService.Model?, SelectedRecipeService.Model?)) {
        
    }
}

let user = UserService()
let recipe = SelectedRecipeService()
let combined = CombinedStreams()
//let stream = combineStreams(first: user, second: recipe) ~>> combined
let stream = user <~> (recipe /* imagine some kind of longer stream definition in here  */) ~>> combined

//So let's talk about the use of a function or an operator here, it definitely breaks up the visual flow of ~>>, and would nest more complex earlier streams inwardly; ie. not read as cleanly flowing from left to right.

//If we tried infix with higher precedence, could we force you to use parens for clear order of operations?
