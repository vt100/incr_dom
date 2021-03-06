open! Core_kernel
open Virtual_dom
open Async_kernel

(** Common module types *)
module type Model = sig
  type t

  (** A function for testing whether the model has changed enough to require refiring
      the incremental graph.

      It's best if the values in the model support a semantically reasonable cutoff
      function which lets you avoid infinite recomputation loops that can otherwise be
      triggered by the visibility checks. For this reason, it's typically a good idea to
      avoid having simple closures stored in the model.

      That said, it does work if you put phys_equal in for the cutoff. *)
  val cutoff : t -> t -> bool
end

module type Action = sig
  type t [@@deriving sexp_of]

  val should_log : t -> bool
end

module type State = sig
  (** Represents the imperative state associated with an application, typically used for
      housing things like communication Async-RPC connections. *)
  type t
end

module type Derived_model = sig
  module Model : Model

  type t

  (** [create] sets up the incremental that performs the shared computations. Sharing
      computations will typically look something like this:

      {[
        let%map shared1 = computation1
        and     shared2 = computation2
        and     shared3 = computation3
        in
        { shared1; shared2; shared3 }
      ]}
  *)
  val create : Model.t Incr.t -> t Incr.t
end

(** The interface for a basic, incrementally rendered application. *)
module type S_simple = sig
  module Model : Model
  module State : State
  module Action : Action

  (** [apply_action] performs modifications to the model as dictated by the action. *)
  val apply_action
    :  Action.t
    -> Model.t
    -> State.t
    -> schedule_action:(Action.t -> unit)
    -> Model.t

  (** If you selectively render certain parts of the model based on what is visible on the
      screen, use [update_visibility] to query the state of the DOM and make the required
      updates in the model.  Otherwise, it can be safely set to the identity function.

      Changes in visibility that cause the page to reflow, thereby causing more changes in
      visibility, must be avoided. In order to make such bugs more visible, cascading
      sequences of [update_visibility] are not prevented.  *)
  val update_visibility : Model.t -> Model.t

  (** [view] sets up the incremental from the model to the virtual DOM.

      [inject] gives you the ability to create event handlers in the virtual DOM. In your
      event handler, call this function on the action you would like to schedule. Virtual
      DOM will automatically delegate that action back to the [Start_app] main loop. *)
  val view : Model.t Incr.t -> inject:(Action.t -> Vdom.Event.t) -> Vdom.Node.t Incr.t

  (** [on_startup] is called once, right after the initial DOM is set to the
      view that corresponds to the initial state.  This is useful for doing
      things like starting up async processes. *)
  val on_startup : schedule_action:(Action.t -> unit) -> Model.t -> State.t Deferred.t

  (** [on_display] is called every time the DOM is updated, with the model just before the
      update and the model just after the update. Use [on_display] to initiate actions. *)
  val on_display
    :  old_model:Model.t
    -> Model.t
    -> State.t
    -> schedule_action:(Action.t -> unit)
    -> unit
end

(** An extension of the basic API that supports the use of a derived model. The purpose of
    this is to allow sharing of an incremental computation between the creation of the
    view and the application of an action. *)
module type S_derived = sig
  module Model : Model
  module State : State
  module Action : Action

  (** [Derived_model] is the data container that allows you to share computations between
      the actions and the view. Any things that the actions need to use should be stored
      in Derived_model.t. Then, in [apply_action], you can call
      [recompute_derived] to retrieve that data and make use of it. *)
  module Derived_model : Derived_model with module Model := Model

  val apply_action
    :  Action.t
    -> Model.t
    -> State.t
    -> schedule_action:(Action.t -> unit)
    -> recompute_derived:(Model.t -> Derived_model.t)
    -> Model.t

  (** [update_visbility] gives you access to both the model and the derived model.

      If you do some intermediate updates to the model, and would like to recompute the
      derived model from those, [recompute_derived model' => derived'] will give you
      that ability. [recompute_derived] updates the model in the incremental graph and
      re-stabilizes the derived model, before giving it back to you. *)
  val update_visibility
    :  Model.t
    -> Derived_model.t
    -> recompute_derived:(Model.t -> Derived_model.t)
    -> Model.t

  val view
    :  Model.t Incr.t
    -> Derived_model.t Incr.t
    -> inject:(Action.t -> Vdom.Event.t)
    -> Vdom.Node.t Incr.t

  val on_startup
    :  schedule_action:(Action.t -> unit)
    -> Model.t
    -> Derived_model.t
    -> State.t Deferred.t

  val on_display
    :  old_model:Model.t
    -> old_derived_model:Derived_model.t
    -> Model.t
    -> Derived_model.t
    -> State.t
    -> schedule_action:(Action.t -> unit)
    -> unit
end

(** This is intended to become the only API for building Incr_dom apps, and S_simple and
    S_derived should be removed soon. This should provide essentially the full
    optimization power of {S_derived}, but should be simpler to use than {!S_simple} *)
module type S_component = sig
  (** The Model represents essentially the complete state of the GUI, including the
      ordinary data that the application is displaying, as well as what you might call the
      "interaction state", things describing where you are in the lifecycle of the GUI,
      what view is currently up, where focus is, etc.  *)
  module Model : sig
    type t

    (** A function for testing whether the model has changed enough to require refiring
        the incremental graph.

        It's best if the values in the model support a semantically reasonable cutoff
        function which lets you avoid infinite recomputation loops that can otherwise be
        triggered by the visibility checks. For this reason, it's typically a good idea to
        avoid having simple closures stored in the model.

        That said, it does work if you put phys_equal in for the cutoff. *)
    val cutoff : t -> t -> bool
  end

  module Action : sig
    type t [@@deriving sexp_of]
  end

  module State : sig
    (** Represents the imperative state associated with an application, typically used for
        housing state associated with communicating with the outside world, like an
        Async-RPC connection. *)
    type t
  end

  (** [on_startup] is called once, right after the initial DOM is set to the view that
      corresponds to the initial state. This is useful for doing things like starting up
      async processes.  Note that this part of the computation does not support any
      incrementality, since it's only run once. *)
  val on_startup : schedule_action:(Action.t -> unit) -> Model.t -> State.t Deferred.t

  (** [create] is a function that incrementally constructs a {!Component}. Note that a
      [Component] supports functions like [apply_action], which return a new [Model.t],
      without taking a model as an explicit input.  The intent is for [apply_action] to
      have access to the current model via its construction

      Here's an example of how this might look in practice.

      {[
        module Model = struct
          type t = { counter : int } [@@deriving fields, compare]

          let cutoff t1 t2 = compare t1 t2 = 0
        end

        module State = struct
          type t = unit
        end

        module Action = struct
          type t = Increment [@@deriving sexp_of]

          let should_log _ = false
        end

        let initial_model = { Model.counter = 0 }

        let on_startup ~schedule_actions _model =
          every (Time_ns.Span.of_sec 1.) (fun () ->
            schedule_actions [ Action.Increment ]);
          Deferred.unit
        ;;

        let create model ~old_model:_ ~inject:_ =
          let open Incr.Let_syntax in
          let%map apply_action =
            let%map counter = model >>| Model.counter in
            fun (Increment : Action.t) _ ~schedule_actions:_ ->
              { Model.counter = counter + 1 }
          and view =
            let%map counter =
              let%map counter = model >>| Model.counter in
              Vdom.Node.div [] [ Vdom.Node.text (Int.to_string counter) ]
            in
            Vdom.Node.body [] [ counter ]
          and model = model in
          (* Note that we don't include [on_display] or [update_visibility], since
             these are optional arguments *)
          Component.create ~apply_action model view
        ;; ]}

      The full code for this example can be found in examples/counter.
  *)
  val create
    :  Model.t Incr.t
    -> old_model:Model.t Incr.t
    (** [old_model] contains the previous version of the model *)
    -> inject:(Action.t -> Vdom.Event.t)
    (** [inject] gives you the ability to create event handlers in the virtual DOM. In
        your event handler, call this function on the action you would like to
        schedule. Virtual DOM will automatically delegate that action back to the
        [Start_app] main loop. *)
    -> (Action.t, Model.t, State.t) Component.t Incr.t
end
