module B = Lib_builder
module T = B.T
module Ty = B.Ty
module L = Name_study
module Arith = B.Arith
module I = Ast__item
module U = Ast__utils

let is_bits name =
  match name.L.postfix with
  | "bits" :: _  -> true
  | _ -> false

let item, str, sg = I.(item,str,sg)

let pps = item Pprintast.structure Pprintast.signature
let ppi = item (fun ppf x -> str pps ppf [x])
    (fun ppf x -> sg pps ppf [x])

type d = (Parsetree.structure,Parsetree.signature) I.item


type side = Str | Sig
let pp_file_extension ppf = function
  | Str -> Fmt.pf ppf ".ml"
  | Sig -> Fmt.pf ppf ".mli"

let map side f x = match side with
  | Str -> (I.str f) (I.str x)
  | Sig -> (I.sg f) (I.sg x)

let print side f ppf x =
  match side with
  | Str -> I.(str f ppf @@ str x)
  | Sig -> I.(sg f ppf @@ sg x)


type context =
  { builtins: B.Name_set.t;
    results: int Ast__result.M.t;
    types: B.item list
  }

let type_to_ast {builtins;results;types} (name,ty) =
  match ty with
  | Ty.Const _  | Option _ | Ptr _ | String | Array (_,_) -> I.nil
  | Result {ok;bad} ->
    Ast__result.make results (name,ok,bad)
  | Name t -> Ast__misc.alias builtins (name,t)
  | FunPtr fn -> Ast__funptr.make types (name,fn)
  | Union fields -> Ast__structured.make types Union (name,fields)
  | Bitset { field_type = Some _; _ } -> I.nil
  | Bitset { field_type = None; _ } -> Ast__bitset.make (name,None)
  | Bitfields {fields;values} ->
    Ast__bitset.make_extended (name,(fields,values))
  | Handle {dispatchable;_} ->  Ast__handle.make ~dispatchable name
  | Enum constrs ->
    if not @@ is_bits name then
      begin
        let is_result = name.main = ["result"] in
        let kind = if is_result then Ast__enum.Poly else Ast__enum.Std in
        Ast__enum.make kind (name,constrs)
      end
    else I.nil
  | Record r ->
    Ast__structured.make types Record (name,r.fields)
  | Record_extensions _ -> (* FIXME *)
    assert false


(*
let pp_open ppf m =
  if m.B.args = [] then
    Fmt.pf ppf "open %a@." L.pp_module m.B.name


let space ppf () = Fmt.pf ppf "@;"
*)

let rec item_to_ast (lib:B.lib) item =
  let types = match B.find_module B.types lib.content.sig' with
    | Some m -> m.sig'
    | None -> raise (Invalid_argument "Printers.pp_item: Missing type module") in
  let ctx = { builtins = lib.builtins; results = lib.result; types } in
  I.rev @@ match item with
  | B.Type (name,t) ->
    type_to_ast ctx (name,t)
  | Const (name,c) -> Ast__misc.Const.make (name,c)
  | Fn f -> Ast__fn.make types f.implementation f.fn
  | Ast s -> s
  | Module m -> module_to_ast lib m
and module_to_ast lib (m:B.module') =
  let s x = [x] in
  I.fmap (item s s)
  @@ U.module' m.name
  @@ List.fold_left (fun sig' (name,mty) -> U.functor' name mty sig' )
  (U.structure
   @@ I.fold_map (item_to_ast lib) m.sig')
  m.args

let atlas ppf modules =
  let pp_alias ppf (m:B.module') =
    Fmt.pf ppf "module %a = Vk__%a@;"
      L.pp_module m.name L.pp_var m.name
  in
  Fmt.pf ppf "@[<v>%a@]@." (Fmt.list pp_alias) modules

let atlas ppfs modules =
  atlas ppfs.I.structure modules;
  atlas ppfs.I.signature modules

let rec submodules = function
  | B.Module m :: q -> m :: submodules q
  | _ :: q -> submodules q
  | [] -> []


let lib (lib:B.lib) =
  let open_file target n =
    Format.formatter_of_out_channel @@ open_out
    @@ Fmt.strf "%s/%s%a" lib.root n pp_file_extension target
  in
  let open_files n =
    { I.structure = open_file Str n; signature = open_file Sig n } in
  atlas (open_files "vk") (submodules lib.content.sig');
  let pp_sub (m:B.module') =
    if not (B.is_empty m) then
      begin
        let filename = Fmt.strf "vk__%a" L.pp_var m.name in
        let ppfs = open_files filename in
        let ast = I.( lib.preambule @*
                      I.fold_map (item_to_ast lib) m.sig') in
        print Str pps (str ppfs) ast;
        print Sig pps (sg ppfs) ast;
        Format.pp_flush_formatter (str ppfs);
        Format.pp_flush_formatter (sg ppfs);
      end
    else Fmt.epr "Printing %a submodule@.%!" L.pp_var m.name
  in
  List.iter pp_sub @@ submodules lib.content.sig'
