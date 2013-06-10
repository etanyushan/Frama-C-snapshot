(**************************************************************************)
(*                                                                        *)
(*  This file is part of WP plug-in of Frama-C.                           *)
(*                                                                        *)
(*  Copyright (C) 2007-2013                                               *)
(*    CEA (Commissariat a l'energie atomique et aux energies              *)
(*         alternatives)                                                  *)
(*                                                                        *)
(*  you can redistribute it and/or modify it under the terms of the GNU   *)
(*  Lesser General Public License as published by the Free Software       *)
(*  Foundation, version 2.1.                                              *)
(*                                                                        *)
(*  It is distributed in the hope that it will be useful,                 *)
(*  but WITHOUT ANY WARRANTY; without even the implied warranty of        *)
(*  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the         *)
(*  GNU Lesser General Public License for more details.                   *)
(*                                                                        *)
(*  See the GNU Lesser General Public License version 2.1                 *)
(*  for more details (enclosed in the file licenses/LGPLv2.1).            *)
(*                                                                        *)
(**************************************************************************)

(* -------------------------------------------------------------------------- *)
(* --- Aggregation of MergeMap and MergeSet                               --- *)
(* -------------------------------------------------------------------------- *)

module type T =
sig
  type t
  val hash : t -> int
  val equal : t -> t -> bool
  val compare : t -> t -> int
end

module type Map =
sig

  type key

  type 'a t

  val empty : 'a t
  val add : key -> 'a -> 'a t -> 'a t
  val mem : key -> 'a t -> bool
  val find : key -> 'a t -> 'a
  val findk : key -> 'a t -> key * 'a

  val map  : ('a -> 'b) -> 'a t -> 'b t
  val mapi : (key -> 'a -> 'b) -> 'a t -> 'b t
  val mapf : (key -> 'a -> 'b option) -> 'a t -> 'b t
  val filter : (key -> 'a -> bool) -> 'a t -> 'a t
  val iter : (key -> 'a -> unit) -> 'a t -> unit
  val fold : (key -> 'a -> 'b -> 'b) -> 'a t -> 'b -> 'b

  val iter_sorted : (key -> 'a -> unit) -> 'a t -> unit
  val fold_sorted : (key -> 'a -> 'b -> 'b) -> 'a t -> 'b -> 'b

  val union : (key -> 'a -> 'a -> 'a) -> 'a t -> 'a t -> 'a t
  val inter : (key -> 'a -> 'a -> 'a) -> 'a t -> 'a t -> 'a t
  val subset : (key -> 'a -> 'b -> bool) -> 'a t -> 'b t -> bool
  val equal : ('a -> 'a -> bool) -> 'a t -> 'a t -> bool

  val iterk : (key -> 'a -> 'b -> unit) -> 'a t -> 'b t -> unit
  val iter2 : (key -> 'a option -> 'b option -> unit) -> 'a t -> 'b t -> unit
  val merge : (key -> 'a option -> 'b option -> 'c option) -> 'a t -> 'b t -> 'c t

  type domain
  val domain : 'a t -> domain

end

module type Set = 
sig
  
  type elt

  type t

  val empty : t
  val add : elt -> t -> t
  val singleton : elt -> t
  val elements : t -> elt list

  val mem : elt -> t -> bool
  val iter : (elt -> unit) -> t -> unit
  val fold : (elt -> 'a -> 'a) -> t -> 'a -> 'a

  val filter : (elt -> bool) -> t -> t
  val partition : (elt -> bool) -> t -> t * t
  val for_all : (elt -> bool) -> t -> bool
  val exists : (elt -> bool) -> t -> bool

  val iter_sorted : (elt -> unit) -> t -> unit
  val fold_sorted : (elt -> 'a -> 'a) -> t -> 'a -> 'a

  val union : t -> t -> t
  val inter : t -> t -> t

  val subset : t -> t -> bool
  val intersect : t -> t -> bool

  type 'a mapping
  val mapping : (elt -> 'a) -> t -> 'a mapping

end

module type S =
sig

  type t
  type set
  type 'a map

  val hash : t -> int
  val equal : t -> t -> bool
  val compare : t -> t -> int

  module Map : Map 
    with type 'a t = 'a map
    and type key = t
    and type domain = set
  module Set : Set 
    with type t = set
    and type elt = t
    and type 'a mapping = 'a map

end


module Make(A : T) =
struct

  type t = A.t
  type set = A.t list Intmap.t
  type 'a map = (A.t * 'a) list Intmap.t

  let hash = A.hash
  let equal = A.equal
  let compare = A.compare

  module Map_i = Mergemap.Make(A)
  module Set_i = Mergeset.Make(A)

  module Map = 
  struct
    include Map_i
    type domain = set
    let domain m = Intmap.map (List.map fst) m
  end

  module Set = 
  struct
    include Set_i
    type 'a mapping = 'a map
    let mapping f m = Intmap.map (List.map (fun k -> k,f k)) m
  end

end