//  FourFour.swift
//  Created by Ryan Cumley on 6/10/20.

import Combine

struct Event<T> {
    let new: T
    let previous: T?
}

///Similar to PassthroughSubject and CurrentValueSubject, Signal<T> provides a bridge between the Imperative and Reactive worlds. The difference is where Passthrough Subject is ephemeral, and CurrentValueSubject is stateful with respect to a single value (ie. you can query CurrentValueSubject at any moment to learn the current 'state'), Signal remembers not just the current state, but the previous state as well, up to a time history depth of (t - 1)
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
    
    private(set) var currentValue: T?
    private(set) var previousValue: T?
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
    }
    
    fileprivate let observations = Set<AnyCancellable>()
}

protocol ReactiveElement {
    associatedtype Model
    var state: Signal<Model> { get }
    
    associatedtype UpstreamModel
    func react(toNew: UpstreamModel)
    func react(toNew: UpstreamModel, withPrevious: UpstreamModel)
}

extension ReactiveElement where UpstreamModel == () {
    func react(toNew: UpstreamModel) {}
    func react(toNew: UpstreamModel, withPrevious: UpstreamModel) {}
}

//extension ReactiveElement {
//    func publisher() -> AnyPublisher<Event<Model>, Never> {
//        return AnyPublisher(state)
//    }
//}

protocol ReactiveRenderer {
    associatedtype Output
    var output: Output { get }
    
    associatedtype UpstreamModel
    func react(toNew: UpstreamModel)
    func react(toNew: UpstreamModel, withPrevious: UpstreamModel)
}

///Concrete Type which allows us to realize the familiar h = f ∘ g `composition` operator
///
///Composes two ReactiveElements into a single ReactiveElement
struct Composite<U: ReactiveElement, M: ReactiveElement>: ReactiveElement where U.Model == M.UpstreamModel {
    typealias Model = M.Model
    typealias UpstreamModel = U.UpstreamModel
    
    let state: Signal<Model>
    let upstream: U
    let downstream: M

    private var cancelToken = Set<AnyCancellable>()

    init(_ upstream: U, downstream: M) {
        self.upstream = upstream
        self.downstream = downstream
        state = downstream.state
        
        upstream.state.sink{ event in
            downstream.react(toNew: event.new)
            event.previous.flatMap{ downstream.react(toNew: event.new, withPrevious: $0) }
                //subscribe the global store here too
        }
        .store(in: &cancelToken)
    }

    func react(toNew: U.UpstreamModel) { upstream.react(toNew: toNew) }
    func react(toNew: U.UpstreamModel, withPrevious: U.UpstreamModel) { upstream.react(toNew: toNew, withPrevious: withPrevious) }
}

struct Leaf<U: ReactiveElement, M: ReactiveRenderer> where U.Model == M.UpstreamModel {
    let upstream: U
    let downstream: M

    private var cancelToken = Set<AnyCancellable>()

    init(_ upstream: U, downstream: M) {
        self.upstream = upstream
        self.downstream = downstream

        upstream.state.sink{ event in
                downstream.react(toNew: event.new)
                event.previous.flatMap{ downstream.react(toNew: event.new, withPrevious: $0) }
                //subscribe the global store here too
            }
            .store(in: &cancelToken)
    }

    func react(toNew: U.UpstreamModel) { upstream.react(toNew: toNew) }
    func react(toNew: U.UpstreamModel, withPrevious: U.UpstreamModel) { upstream.react(toNew: toNew, withPrevious: withPrevious) }
}


///Concrete Type which allows us to realize the familiar covariant functor
struct Mapped<U: ReactiveElement,V>: ReactiveElement {
    typealias Model = V
    typealias UpstreamModel = U.UpstreamModel
    
    let state: Signal<Model>
    let upstream: U

    private var cancelToken = Set<AnyCancellable>()
    
    init(_ upstream: U, map: (U.Model) -> V) {
        self.upstream = upstream
        let mappedCurrent = upstream.state.currentValue.flatMap{ map($0) }
        let mappedPrevious = upstream.state.previousValue.flatMap{ map($0) }
        state = Signal<Model>(current: mappedCurrent, previous: mappedPrevious)
        
//        let fire: (U.Model) -> () = {
//            self.state.update(map($0))
//        }
        
//        upstream.state
//            .sink{ fire($0.new) }
//            .store(in: &cancelToken)
            //Do NOT send this event to the global store, since it will only matter when a downstream subscriber receives it
    }
    
    func react(toNew: U.UpstreamModel) { self.upstream.react(toNew: toNew) }
    func react(toNew: U.UpstreamModel, withPrevious: U.UpstreamModel) { upstream.react(toNew: toNew, withPrevious: withPrevious) }
}

precedencegroup ReactiveStreamPrecedence {
    lowerThan: TernaryPrecedence
    higherThan: AssignmentPrecedence
    associativity: left
    assignment: false
}

infix operator ~>>: ReactiveStreamPrecedence

//Let's see if we can cut out the wrapping structs with Combine types. I think AnyPublisher<> can get me there with the right signature specializations.

// I didn't class constrain the ReactiveElement protocol, so I'm assuming that you are managing the lifecycle of the type you're passing into a stream. However Signal<T> is a class, so I can work with reference semantics
//Perhaps Signal<T> just needs to expose a store for cancellable tokens or a store for upstream/downstream Signal references? Some interesting ARC consequences here.

///Join two reactive elements together
func ~>> <S: ReactiveElement, C: ReactiveElement>(lhs: S, rhs: C) -> Signal<C.Model> where S.Model == C.UpstreamModel {

    
    return rhs.state
}

func ~>> <S,C: ReactiveElement>(lhs: Signal<S>, rhs: C) -> Signal<C.Model> where S == C.UpstreamModel {
    
    
    
    return rhs.state
}

func ~>> <S,C: ReactiveRenderer>(lhs: Signal<S>, rhs: C) -> C.Output where S == C.UpstreamModel {
    
    
    
    return rhs.output
}


///Join two reactive elements together
func ~>> <S: ReactiveElement, C: ReactiveElement, R: ReactiveElement>(lhs: S, rhs: C) -> R where S.Model == C.UpstreamModel, R.Model == C.Model, R.UpstreamModel == S.UpstreamModel {
    return Composite(lhs, downstream: rhs) as! R
}

///Use a map to transform the published model of a ReactiveElement
func ~>> <Source: ReactiveElement, Output: ReactiveElement,T,V>(lhs: Source, rhs: @escaping (T) -> V) -> Output where Source.Model == T, Output.Model == V {
    return Mapped(lhs, map: rhs) as! Output
}

///Subscribe a terminating element to a reactive stream, returning the reified output.
func ~>> <Source: ReactiveElement, Renderer: ReactiveRenderer>(lhs: Source, rhs: Renderer) -> Renderer.Output where Source.Model == Renderer.UpstreamModel {
    lhs.state.sink{ event in
        rhs.react(toNew: event.new)
        event.previous.flatMap{ rhs.react(toNew: event.new, withPrevious: $0) }

        //send this to the global store
    }
    //TODO: store the AnyCancellable in an appropriate place

    return rhs.output
}







//  <Done!> 1. Make a DiffableValueSubject that does the CurrentValueSubject dance but holds the previous state too. This guy will get used everywhere!

// 2. Global implicit redux store

// 3. zip, combineLatest, (U,V,X) etc...
