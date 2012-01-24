(*
    Copyright © 2011 MLstate

    This file is part of OPA.

    OPA is free software: you can redistribute it and/or modify it under the
    terms of the GNU Affero General Public License, version 3, as published by
    the Free Software Foundation.

    OPA is distributed in the hope that it will be useful, but WITHOUT ANY
    WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
    FOR A PARTICULAR PURPOSE. See the GNU Affero General Public License for
    more details.

    You should have received a copy of the GNU Affero General Public License
    along with OPA. If not, see <http://www.gnu.org/licenses/>.
*)
(*
    @author Louis Gesbert
**)

module Arg = Base.Arg

module Graph = SchemaGraphLib.SchemaGraph.SchemaGraph0

module DbAst = QmlAst.Db

module C = DbGen_common

type engine = Db3 | Mongo

module Args = struct

  type options = {
    engine : engine
  }

  let default = {
    engine = Db3
  }

  let descr = function
    | Db3   -> "Db3"
    | Mongo -> "Mongo"

  let assoc = [("mongo", Mongo); ("db3"), Db3]

  let r = ref default

  let options = [
    ("--database", Arg.spec_fun_of_assoc (fun s -> r := {engine=s}) assoc,
     "Select kind of database (db3|mongo)");
  ]

  let get_engine() = !r.engine

end

let settyp = DbGen_common.settyp

module Sch = Schema_private
module Schema = struct

  type t = Sch.meta_schema

  type database = {
    name : string;
    ident : Ident.t;
    package : ObjectFiles.package_name;
  }

  type query = QmlAst.expr QmlAst.Db.query

  type set_kind =
    | Map of QmlAst.ty * QmlAst.ty
    | DbSet of QmlAst.ty

  type node_kind =
    | Compose of (string * string list) list
    | Plain
    | Partial of string list * string list
    | SetAccess of set_kind * string list * (bool * query) option (*bool == unique*)

  type node = {
    ty : QmlAst.ty;
    kind : node_kind;
    database : database;
    default : QmlAst.expr;
  }

  let pp_query fmt _e = Format.fprintf fmt "todo query"

  let pp_set_kind fmt = function
    | DbSet ty -> Format.fprintf fmt "dbset(%a)" QmlPrint.pp#ty ty
    | Map (kt, vt) -> Format.fprintf fmt "map(%a, %a)" QmlPrint.pp#ty kt QmlPrint.pp#ty vt

  let pp_kind fmt kind =
    let pp_path fmt p =
      List.iter (Format.fprintf fmt "/%s") p;
      Format.fprintf fmt "/";
    in
    match kind with
    | Plain -> Format.fprintf fmt "plain"
    | Partial (p0, p1) -> Format.fprintf fmt "partial (%a, %a)" pp_path p0 pp_path p1
    | Compose _ -> Format.fprintf fmt "cmp (...)"
    | SetAccess (sk, path, query) ->
        Format.fprintf fmt "@[<hov>access to %a : %a with %a@]"
          pp_path path
          pp_set_kind sk
          (Option.pp_none pp_query) query

  let pp_node fmt node =
    Format.fprintf fmt "{@[<hov>type : %a; kind : %a; ...@]}"
      QmlPrint.pp#ty node.ty
      pp_kind node.kind

  let mapi = Sch.mapi
  let initial = Sch.initial
  let is_empty = Sch.is_empty_or_unused
  let register_path = Sch.register_path
  let register_default = Sch.register_default
  let register_db_declaration = Sch.register_db_declaration
  let register_new_db_value = Sch.register_new_db_value
(*   let get_type_of_path = get_type_of_path *)
  (* let preprocess_path = preprocess_path *)
  let preprocess_paths_expr = Sch.preprocess_paths_expr
  let preprocess_paths_code_elt = Sch.preprocess_paths_code_elt
  let preprocess_paths_ast = Sch.preprocess_paths_ast
  let finalize = Sch.finalize
  let of_package = Sch.of_package
  let merge = Sch.merge
  let map_types = Sch.map_types
  let map_expr = Sch.map_expr
  let fold_expr = Sch.fold_expr
  let foldmap_expr = Sch.foldmap_expr
  let from_gml s =
    StringListMap.singleton []
      ({ Sch.ident = Ident.next "dummy_from_gml";
         Sch.context = QmlError.Context.pos (FilePos.nopos "built from gml");
         Sch.path_aliases = [];
         Sch.options = [];
         Sch.schema = Schema_io.from_gml_string s;
         Sch.virtual_path = Sch.PathMap.empty;
       })
  let to_dot t chan =
    StringListMap.iter
      (fun _key db_def ->
         (* output_string chan (String.concat "/" key); *)
         (* output_char chan '\n'; *)
         Schema_io.to_dot db_def.Sch.schema chan)
      t

  let find_db_def t db_ident_opt =
    if StringListMap.size t = 1 && db_ident_opt = None
    then StringListMap.min t
    else
      StringListMap.min (* may raise Not_found *)
        (StringListMap.filter_val
           (fun db_def -> db_ident_opt = Some (Ident.original_name db_def.Sch.ident))
           t)
  let db_to_dot t db_ident_opt chan =
    let _, db_def = find_db_def t db_ident_opt in
    Schema_io.to_dot db_def.Sch.schema chan
  let db_to_gml t db_ident_opt chan =
    let _, db_def = find_db_def t db_ident_opt in
    Schema_io.to_gml db_def.Sch.schema chan

  let get_db_declaration = Sch.get_db_declaration

  let db_declaration = Sch.db_declaration

  let get_database schema name =
    let declaration = StringListMap.find [name] schema in
    {
      name;
      ident = declaration.Sch.ident;
      package = "todo" (*TODO*);
    }

  exception Vertex of Graph.vertex

  let get_root schema = try
    Graph.iter_vertex (fun v -> if SchemaGraphLib.is_root v then (raise (Vertex v))) schema;
    OManager.i_error "Don't find the root node on database schema";
  with Vertex v -> v


  (** Get the next node on given [schema] according to the path
      [fragment]. *)
  let rec next schema node fragment =
    let can_succ e =
      match (fragment, e.C.label) with
      | (DbAst.FldKey s0, C.Field (s1, _)) when s0 = s1 -> true
      | (DbAst.FldKey _s0, _) -> false
      | (DbAst.ExprKey _, C.Multi_edge _) -> true
      | (DbAst.Query _, C.Multi_edge _) -> true
      | _ -> assert false (* TODO *)
    in
    let v = match (Graph.V.label node).C.nlabel with
    | C.Sum ->
        Graph.fold_succ
          (fun node acc -> try
             let e = next schema node fragment in
             match acc with
             | None -> Some e
             | Some _ -> assert false
           with Not_found -> acc)
          schema node None
    | _ ->
        let edge = Graph.fold_succ_e
          (fun edge ->
             let (_, e, _) = edge in
             function
               | None when can_succ e -> Some edge
               | Some _ when can_succ e -> assert false
               | x -> x
          ) schema node None
        in Option.map Graph.E.dst edge
    in
    match v with
    | None -> raise Not_found
    | Some v -> (v : Graph.vertex)

  let get_node annotmap (schema:t) path =
    let dbname, path= match path with
    | DbAst.FldKey k::path -> k, path
    | _ -> assert false (* TODO *)
    in
    let declaration = StringListMap.find [dbname] schema in
    let database = get_database schema dbname in
    let llschema = declaration.Sch.schema in
    let f (node, kind, path) fragment =
      let next = next llschema node fragment in
      let get_setkind schema node =
        match Graph.succ_e schema node with
        | [edge] -> begin match (Graph.E.label edge).C.label with
          | C.Multi_edge C.Kint ->
              Map (QmlAst.TypeConst QmlAst.TyInt, next.C.ty)
          | C.Multi_edge C.Kstring ->
              Map (QmlAst.TypeConst QmlAst.TyString, next.C.ty)
          | C.Multi_edge (C.Kfields _) -> DbSet next.C.ty
          | _ -> assert false
          end
        | [] -> raise Not_found
        | _ -> raise Not_found
      in
      match fragment with
      | DbAst.ExprKey expr ->
          let setkind = get_setkind llschema node in
          let kind = SetAccess (setkind, path, Some (true, DbAst.QEq expr)) in
          (next, kind, path)

      | DbAst.FldKey key ->
          let kind =
            let nlabel = Graph.V.label next in
            match nlabel.C.nlabel with
            | C.Multi -> SetAccess (get_setkind llschema next, key::path, None)
            | _ -> match kind, nlabel.C.plain with
              | Compose _, true -> Plain
              | Partial (path, part), false -> Partial (path, key::part)
              | Plain, false -> Partial (path, key::[])
              | Compose c, false -> Compose c
              | Partial _, true -> assert false
              | Plain, true -> assert false
              | _, _ -> assert false
          in let path = key::path
          in (next, kind, path)
      | DbAst.Query query ->
          begin match kind with
          | SetAccess (_k, path, None) ->
              let kind = SetAccess (get_setkind llschema node, path, Some (false, query)) in
              (next, kind, path)
          | SetAccess (_, _path, Some _) -> assert false
          | _ -> assert false
          end
      | _ -> assert false

    in
    let (node, kind, _path) =
      List.fold_left f (get_root llschema, Compose [], []) path in
    let kind =
      match kind with
      | Compose _ -> (
          match (Graph.V.label node).C.nlabel with
          | C.Product ->
              let path = List.map
                (function
                   | DbAst.FldKey k -> k
                   | _ -> assert false) path in
              Compose (List.map
                         (fun edge ->
                            let sname = SchemaGraphLib.fieldname_of_edge edge
                            in sname, dbname::path @ [sname])
                         (Graph.succ_e llschema node)
                      )
          | _ -> assert false
        )
      | Partial (path, part) ->
          Partial (List.rev path, List.rev part)
      | SetAccess (k, path, query) ->
          SetAccess (k, List.rev path, query)
      | Plain -> Plain
    in
    let (annotmap, default) =
      DbGen_private.Default.expr
        annotmap
        llschema
        node
    in
    annotmap,
    {
      database; kind; default;
      ty = node.DbGen_common.ty;
    }

  module HacksForPositions = Sch.HacksForPositions
end

module type S = sig include DbGenByPass.S end

type dbinfo = DbGen_private.dbinfo

let merge_dbinfo = DbGen_private.merge_dbinfo

module DbGen ( Arg : DbGenByPass.S ) = struct

  module Access = DbGen_private.DatabaseAccess (Arg)
  let initialize = Access.initialize

  let replace_path_exprs = Access.replace_path_exprs
  let replace_path_code_elt = Access.replace_path_code_elt
  let replace_path_ast = Access.replace_path_ast
end

module DbGenByPass = DbGenByPass

let warning_set =
  WarningClass.Set.create_from_list [
    WarningClass.dbgen;
    WarningClass.dbgen_schema;
  ]
