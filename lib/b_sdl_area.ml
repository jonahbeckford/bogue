(* SDL Area Widget *)
(* This file is part of BOGUE *)

module Box = B_box
module Var = B_var
module Draw = B_draw
module Flow = B_flow
module Time = B_time
module Trigger = B_trigger

open B_utils

type draw_element = {
  id : int;
  name : string;
  mutable disable : bool;
  f : Tsdl.Sdl.renderer -> unit
}

type t = {
  box : Box.t;
  (* TODO: in fact one could use 2 textures: one for the Box, one for the Area:
     because the Box contains a background, and it's not always necessary to
     clear the background each time we want to clear the Area... *)
  sheet : (draw_element Flow.t) Var.t;
  (* A sheet should be a data structure that is very fast to append AND to
     iterate, AND whose iteration can be split. Queues would be perfect for the
     first two. We implemented Flow for this purpose. *)
  mutable update : bool;
  (* if [update] is false, we just draw the box texture without applying the
     [sheet] *)
  timeout : int
}

let new_id = fresh_int ()

let create ~width ~height ?style ?(timeout = 50) () =
  { box = Box.create ~width ~height ?style ();
    sheet = Var.create (Flow.create ());
    update = true;
    timeout
  }

let sprint el =
  Printf.sprintf "%u%s" el.id
    (if el.name = "" then "" else Printf.sprintf " (%s)" el.name)

let unload area =
  Box.unload area.box

let update area =
  area.update <- true;
  Var.protect_fn area.sheet Flow.rewind

let clear area =
  Var.set area.sheet (Flow.create ());
  update area

let free area =
  Box.free area.box;
  clear area

(* Add the element to the sheet *)
let add_element area el =
  Var.protect_fn area.sheet (fun q ->
      printd debug_custom "Adding element %s to the SDL Area." (sprint el);
      Flow.add el q;
      Flow.rewind q; (* we do this here just to avoid calling [update] *));
  area.update <- true

(* Add a drawing function to the sheet and return the corresponding element. The
   function should be fast, otherwise it will block the UI when the sheet is
   executed.  *)
let add_get area ?(name = "") ?(disable = false) f =
  let el = { id = new_id (); name; disable; f} in
  add_element area el;
  el

(* Just add, don't return the element *)
let add area ?name f =
  add_get area ?name f
  |> ignore

(* Remove the element from the sheet. OK to be slow. *)
let remove_element area element =
  update area;
  Var.protect_fn area.sheet (fun q ->
      try Flow.remove_first_match (fun el -> el.id = element.id) q
      with Not_found ->
        printd debug_error "Element %s not found in SDL Area" (sprint element))

let has_element area element =
  Var.protect_fn area.sheet (fun q ->
      Flow.rewind q;
      Flow.exists (fun el -> el.id = element.id) q)

let disable element =
  element.disable <- true

let enable element =
  element.disable <- false

let size area =
  Box.size area.box

let resize size area =
  update area;
  Box.resize size area.box

(* size in physical pixels *)
let drawing_size area =
  match Var.get area.box.render with
  | Some t -> Draw.tex_size t
  | None -> Box.size area.box
            |> Draw.to_pixels

let to_pixels = Draw.to_pixels

(* Convenient shortcuts to some Draw functions. Downside: they cannot adapt
   easily to resizing the area. See example 49. *)

let draw_circle area ~color ~thick ~radius (x, y) =
  add area (Draw.circle ~color ~thick ~radius ~x ~y)

let draw_rectangle area ~color ~thick ~w ~h (x, y) =
  add area (Draw.rectangle ~color ~w ~h ~thick ~x ~y)

let draw_line area ~color ~thick (x0, y0) (x1, y1) =
  if thick = 1
  then add area (fun renderer ->
      Draw.set_color renderer color;
      go (Tsdl.Sdl.render_draw_line renderer x0 y0 x1 y1))
  else add area (Draw.line ~color ~thick ~x0 ~y0 ~x1 ~y1)

(* Direct access to the texture *)

let get_texture area =
  Var.get area.box.render

let set_texture area texture =
  Var.set area.box.render (Some texture);
  area.update <- false

(************* display ***********)

let display wid canvas layer area g =
  if area.update then Box.unload_texture area.box;
  let blits = Box.display canvas layer area.box g in
  if not area.update && Flow.end_reached (Var.get area.sheet) then blits
  else (* Now we draw directly on the Box texture *)
    let () = printd debug_graphics "Rendering SDL Area of length %u"
        (Flow.length (Var.get area.sheet)) in
    let renderer = canvas.renderer in
    let tex = match Var.get area.box.render with
      | Some t -> t
      | None -> failwith "The Sdl_area texture should have been create by Box \
                          already" in
    let save_target = Draw.push_target ~clear:false canvas.renderer tex in

    (* Executing the drawing functions cannot be done in a separate Thread
       because it uses directly the SDL Renderer API. Hence we have a basic
       timeout mechanism in order to be nice to the rest of the GUI. *)
    (* TODO Currently this mechanism does not work well (user events are
       blocked) because we need to change the way events are consumed in the
       main loop. *)
    let t0 = Time.now () in
    Var.protect_fn area.sheet (fun q ->
        Tsdl.Sdl.(set_render_draw_blend_mode renderer Blend.mode_blend) |> go;
        Flow.iter_until (fun el ->
            if not el.disable then begin
              printd debug_graphics "Executing SDL_Area element %s." (sprint el);
              el.f renderer;
              Time.now () - t0 > area.timeout
            end
            else false)
          q;
        if not (Flow.end_reached q) then begin
          printd (debug_board + debug_warning)
            "The rest of the SDL Area will be rendered later";
          Trigger.push_redraw wid
        end);
    Draw.pop_target canvas.renderer save_target;
    area.update <- false;
    blits
