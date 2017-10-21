
module Aliases= struct
  module L = Name_study
  module B = Lib_builder
  module Ty = Lib_builder.Ty
  module H = Ast_helper
  module Exp = H.Exp
  module P = Parsetree
  module Inspect = Ast__inspect
  module C = Ast__common
  module M = Enkindler_common.StringMap
end
open Aliases
open Ast__item
open Ast__utils

(*   let debug fmt = Fmt.epr ( "Debug:"^^ fmt ^^ "@.%!") *)

let unique, reset_uid = C.id_maker ()

let addr_f t exp =
  [%expr [%e ident(qn t "addr")] [%e exp] ]

let make_f t exp =
  [%expr [%e ident(qn t "unsafe_make")] [%e exp] ]


let regularize types ty exp= match ty with
  | Ty.Ptr Name t | Const Ptr Name t when Inspect.is_record types t ->
    addr_f t exp
  | Option Ptr Name _ -> [%expr may [%e C.addr exp] ]
  | _ ->  exp


let regularize_fields types fields =
  let reg f =
    match f.Ty.field with
    | Simple(n, (Ptr Name t | Const Ptr Name t)) when Inspect.is_record types t ->
      { f with field = Simple(n, Name t) }
    | Simple(n, Option Ptr Name t) when Inspect.is_record types t ->
      { f with field = Simple(n, Option (Name t)) }
    | _ -> f
  in
  List.map reg fields

let annotate fmt =
  Fmt.kstrf (fun s e -> Exp.attr e @@
              (nloc "debug", P.PStr [H.Str.eval @@ string s ]))
    fmt

let arg_types (fn:Ty.fn) =
  Ast__funptr.expand @@ List.map snd @@ Ty.flatten_fn_fields fn.args

let foreign fn =
  let args = arg_types fn in
  [%expr foreign [%e string fn.original_name] [%e Ast__funptr.mkty args fn.return]]

let make_simple (fn:Ty.fn) =
  [%stri let [%p (var fn.name).p] = [%e foreign fn] ]

let apply_gen get name vars args =
  let get f = Asttypes.Nolabel, get vars f in
  let add_arg l = function
    | Ty.Array_f { array ; index } ->
      (get array) :: (get index) :: l
    | Simple field -> get field :: l
    | Record_extension _  -> assert false in
  let args = List.rev @@ List.fold_left add_arg [] args in
  Exp.apply name args

let apply = apply_gen (fun vars (f,_ty) -> ex (M.find @@ varname f) vars)


let get_r types vars (f,ty) =
  regularize types ty @@ ex (M.find @@ varname f) vars
let apply_regular types = apply_gen (get_r types)

let mkfn_simple fields =
  let build (f,vars) (name,_ty) =
    let u = unique (varname name) in
    (fun body -> f [%expr fun [%p u.p] -> [%e body] ]),
    M.add (varname name) u vars in
  List.fold_left build ((fun x -> x), M.empty) fields

let make_regular types fn =
  let args = Inspect.to_fields fn.Ty.args in
  let f = unique "f" in
  let def body =
    [%stri let [%p pat var fn.name] =
             let [%p f.p] = [%e foreign fn] in
             [%e body] ] in
  def begin
    let fe, vars = mkfn_simple @@ Ty.flatten_fields args in
    fe @@ apply_regular types f.e vars args
  end

let make_labelled m fn =
  let args = Inspect.to_fields fn.Ty.args in
  let k, vars = Ast__structured.mkfun args in
  [%stri let make =
           [%e k @@ apply (ident @@ qn m @@ varname fn.name) vars args]
  ]


module Option = struct
  let map f = function
    | None -> None
    | Some x -> Some (f x)
end

let rec ptr_to_name ?(ellide=true) = function
  | Ty.Option t ->
    Option.map (fun (ty,name) -> (Ty.Option ty, name))
      (ptr_to_name ~ellide t)
  | Ty.Name t -> Some(Ty.Name t, t )
  | Ty.Ptr p | Array(_,p) ->
    Option.map (fun (p,elt) -> if ellide then (p,elt) else (Ty.Ptr p, elt) )
    @@ ptr_to_name ~ellide:false p
  | _ -> None

let nullptr_typ p = [%expr nullptr [%e p]]
let allocate_n ty n = [%expr Ctypes.allocate_n [%e ty] [%e n]]
let allocate ty value = [%expr Ctypes.allocate [%e ty] [%e value]]


(* Allocate composite fields *)
let allocate_field types fields vars f body  =
  let get f = M.find (varname f) vars in
  match f.Ty.field with
  | Simple(f, Array(Some p , Name elt)) ->
    let array = get f in
    let size =  get @@ C.index_name f in
    let n = Ast__structured.array_index ~conv:false (ex get) types fields p in
    [%expr let [%p size.p] = [%e n ] in
      let [%p array.p ] =
        Ctypes.allocate_n [%e (var elt).e ] [%e size.e ] in
      [%e body]
    ]
  | Simple(f, Option _ ) ->
    let f = get f in
    [%expr let [%p f.p ] = None in [%e body] ]
  | Simple(f, Name t) when Inspect.is_record types t ->
    let f = get f in
    [%expr let [%p f.p ] = [%e Ast__structured.unsafe_make t] in [%e body] ]
  | Simple (f,t) ->
    begin let f = get f in
      match ptr_to_name t with
      | None -> body
      | Some (ty,_) ->
        let alloc = C.wrap_opt t @@ allocate_n
            (Ast__type.converter true ty) [%expr 1] in
        [%expr let [%p f.p] = [%e alloc] in [%e body] ]
    end
  | Array_f { array=a, Option _; index=i, Ptr Option Name t } ->
    let a = get a and i = get i in
    [%expr let [%p i.p] = Ctypes.allocate [%e ex var L.(t//"opt")] None in
      let [%p a.p] = Option.None in [%e body]
    ]
  | Array_f { array=a, elt; index=i, size } ->
    let a = get a and i = get i in
    begin match ptr_to_name elt, ptr_to_name size with
      | None, _ | _, None -> body
      | Some (e,_), Some(s,_) ->
        let alloc_size = C.wrap_opt size @@ allocate_n
            (Ast__type.converter ~degraded:true s) [%expr 1]
        and alloc_elt = nullptr_typ (Ast__type.converter ~degraded:true e) in
        [%expr let [%p a.p] = [%e alloc_elt] and [%p i.p] = [%e alloc_size] in
          body
        ]
    end
  | _ -> C.not_implemented "Native function for field type %a" Ty.pp_fn_field f

(* Array output parameter needs to be allocated in two times:
   first the index parameter is allocated,
   then the function is applied and fills the actual value of the
   index parameter, which enable us to allocate the output array *)
let secondary_allocate_field vars f body = match f.Ty.field with
  | Array_f { array = a, tya; index = i, it  } ->
    let a = M.find (varname a) vars and i = M.find (varname i) vars in
    let size = Ast__structured.int_of_ty i.e it in
    begin match ptr_to_name tya with
      | Some (Option elt, _ ) ->
        let alloc = allocate_n (Ast__type.converter ~degraded:true elt) size in
        [%expr let [%p a.p] = [%e C.wrap_opt tya @@ alloc] in [%e body] ]
      | Some _ | None -> assert false end
  | _ -> body

let extract_opt input output nullptr map body =
  let scrutinee = unique "scrutinee" in
  [%expr let [%p output.p] = match [%e input] with
      | None -> None, [%e nullptr]
      | Some [%p scrutinee.p] -> [%e map scrutinee.e] in  [%e body]
  ]

let len' x = [%expr Ctypes.CArray.length [%e x] ]
let len ty x = Ast__structured.ty_of_int ty @@ len' x

let start = Ast__structured.start
let extract_array input (ty,index) array body =
  [%expr
    let [%p index] = [%e len ty input] in
    let [%p array] = [%e start input] in
    [%e body]
  ]

let (<*>) x y =
  { p = [%pat? [%p x.p], [%p y.p] ]; e = [%expr [%e x.e], [%e y.e] ] }

let nullptr = Ast__structured.nullptr

let input_expand vars f body = match f with
  | Ty.Array_f { array= (a, tya ) ; index = (i, ty )  } as f ->
    let a = M.find (varname a) vars and i = M.find (varname i) vars in
    if Inspect.is_option_f f then
      let extract_array input =
        [%expr [%e len ty input], [%e start input]] in
      extract_opt a.e ( i <*> a )
        (nullptr tya) extract_array body
    else
      extract_array a.e (ty,i.p) a.p body
  | Simple(f, Array(Some Path _, ty)) ->
    let f = M.find (varname f) vars in
    if Inspect.is_option ty then
      [%expr let [%p f.p] = match [%e f.e] with
          | Option.Some [%p f.p] -> Option.Some [%e start f.e]
          | Option.None -> Option.None in [%e body]
      ]
    else
      [%expr let [%p f.p] =[%e start f.e] in [%e body] ]
  | _ -> body

let tuple l = Exp.tuple l

let ty_of_int = Ast__structured.ty_of_int
let int_of_ty = Ast__structured.int_of_ty
let from_ptr x y = [%expr Ctypes.CArray.from_ptr [%e x] [%e y] ]
let to_output types vars f =
  let get x = ex (M.find @@ varname x) vars in
  match f.Ty.field with
  | Ty.Array_f { array = (n, Ty.Option _) ; index = i , it } ->
    from_ptr [%expr unwrap [%e get n]] (int_of_ty (get i) it)
  | Ty.Array_f { array = (n,_) ; _ } -> get n
  | Simple(f, Array(Some(Path _), Name _ )) ->
    from_ptr (get f)
      (ex (M.find @@ varname @@ C.index_name f) vars)
  | Simple(n, Name t)  when Inspect.is_record types t ->  get n
  | Simple(n, Ptr Option _) ->
    [%expr unwrap (Ctypes.(!@) [%e get n]) ]
  | Simple(n, _) -> [%expr Ctypes.(!@) [%e get n] ]
  | Record_extension _ ->
    C.not_implemented "Record extension used as a function argument"

let join ty res outputs =
  let n = List.length outputs in
  if Inspect.is_result ty then
    let u = unique "ok" in
    let outputs = if outputs = [] then [[%expr ()]] else outputs in
    [%expr match [%e res] with
      | Error _ as e -> e
      | Ok [%p u.p] -> Ok [%e tuple @@ u.e :: outputs]
    ]
  else if  n = 0 then
    res
  else if Inspect.is_void ty then
    tuple outputs
  else
    tuple @@ res :: outputs

let look_out vars output = List.fold_left ( fun (l,vars) f ->
    match f.Ty.field with
    | Ty.Array_f { array = a, _ ; index = i, _ } ->
      let u = unique (varname a) and v = unique (varname i) in
      u.e :: l, vars |> M.add (varname i) u |> M.add (varname a) v
    | Simple(n, Array _ ) ->
      let u = unique (varname n) and v = unique "size" in
      u.e :: l, vars |> M.add (varname n) v |> M.add (varname @@ C.index_name n) u
    | f ->
      let u = unique (varname @@ C.repr_name f) in
      u.e :: l, vars |> M.add (varname @@ C.repr_name f) u
  ) ([], vars) output

let make_native types (fn:Ty.fn)=
  reset_uid ();
  let rargs = regularize_fields types fn.args in
  let fold f l body = List.fold_right ((@@) f ) l body in
  let input, output =
    List.partition (fun r -> r.Ty.dir = In || r.dir = In_Out) rargs in
  let apply_twice = List.exists
      (function { Ty.field = Array_f _ ; _ } -> true | _ -> false) output in
  let tyret = fn.return in
  let input' = Inspect.to_fields input in
  let all = Inspect.to_fields fn.args in
  let fun', vars = Ast__structured.mkfun input' in
  let _, vars = look_out vars output in
  (fun x -> [%stri let [%p pat var fn.name] = [%e x] ]) @@
  fun' @@
  fold (input_expand vars) input' @@
  fold (allocate_field types input' vars) output @@
  let apply = apply_regular types (ex var fn.name) vars all in
  let res = unique "res" in
  let result =
    let outs = List.map (to_output types vars) output in
    [%expr let [%p res.p] = [%e apply] in [%e join tyret res.e outs] ] in
  let secondary = fold (secondary_allocate_field vars) output in
  if not apply_twice then
    result
  else if Inspect.is_result fn.return then
    [%expr match [%e apply] with
      | Error _ as e -> e
      | Ok _ -> [%e secondary result]
    ]
  else
    [%expr [%e apply]; [%e secondary result] ]

let make types = function
  | B.Regular -> make_regular types
  | Native -> make_native types
  | Raw -> make_simple
