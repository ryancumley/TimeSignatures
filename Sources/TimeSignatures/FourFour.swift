//  FourFour.swift
//  Created by Ryan Cumley on 6/10/20.

import Combine

protocol ReactiveElement {
    associatedtype Model
    var state: CurrentValueSubject<Model,Never> { get }
    
    associatedtype UpstreamModel
    func react(toNew: UpstreamModel)
    func react(toNew: UpstreamModel, withPrevious: UpstreamModel)
}

extension ReactiveElement where UpstreamModel == () {
    func react(toNew: UpstreamModel) {}
    func react(toNew: UpstreamModel, withPrevious: UpstreamModel) {}
}

protocol ReactiveRenderer {
    associatedtype Output
    var output: Output { get }
    
    associatedtype UpstreamModel
    func react(toNew: UpstreamModel)
    func react(toNew: UpstreamModel, withPrevious: UpstreamModel)
}

///Concrete Type which allows us to realize the familiar h = f ∘ g `composition` operator
struct Composite<U: ReactiveElement, M: ReactiveElement>: ReactiveElement where U.Model == M.UpstreamModel {
    typealias Model = M.Model
    typealias UpstreamModel = U.UpstreamModel
    
    let state: CurrentValueSubject<M.Model, Never>
    let upstream: U
    let downstream: M
    
    init(_ upstream: U, downstream: M) {
        self.upstream = upstream
        self.downstream = downstream
        state = downstream.state
        
        upstream.state.sink{
            downstream.react(toNew: $0)
            //TODO: Diffable dance
        }
        //TODO: store the AnyCancellable in an appropriate place
    }
    
    func react(toNew: U.UpstreamModel) { upstream.react(toNew: toNew) }
    func react(toNew: U.UpstreamModel, withPrevious: U.UpstreamModel) { upstream.react(toNew: toNew, withPrevious: withPrevious) }
}

class Mapped<U: ReactiveElement,V>: ReactiveElement {
    typealias Model = V
    typealias UpstreamModel = U.UpstreamModel
    
    let state: CurrentValueSubject<V, Never>
    let upstream: U
    
    init(_ upstream: U, map: @escaping (U.Model) -> V) {
        self.upstream = upstream
        state = CurrentValueSubject(map(upstream.state.value))
        
        upstream.state.sink{ self.state.send(map($0)) }
        //TODO: store the AnyCancellable in an appropriate place
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
    lhs.state.sink{
        rhs.react(toNew: $0)
    }
    //TODO: store the AnyCancellable in an appropriate place

    return rhs.output
}




// 1. Make a DiffableValueSubject that does the CurrentValueSubject dance but holds the previous state too. This guy will get used everywhere!

// 2. Global implicit redux store

// 3. zip, combineLatest, (U,V,X) etc...
