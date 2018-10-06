open Base
open Stdio

let unsupported_functions =
  Set.of_list (module String) [ "bincount"; "stft"; "group_norm"; "layer_norm" ]

let yaml_error yaml ~msg =
  Printf.sprintf "%s, %s" msg (Yaml.to_string_exn yaml)
  |> failwith

let extract_list = function
  | `A l -> l
  | yaml -> yaml_error yaml ~msg:"expected list"

let extract_map = function
  | `O map -> Map.of_alist_multi (module String) map
  | yaml -> yaml_error yaml ~msg:"expected map"

let extract_string = function
  | `String s -> s
  | yaml -> yaml_error yaml ~msg:"expected string"

let rec contains_string ~str = function
  | `A l -> List.exists l ~f:(contains_string ~str)
  | `O l -> List.exists l ~f:(fun (_, y) -> contains_string y ~str)
  | `String s when String.is_substring s ~substring:str -> true
  | _ -> false

module Function = struct
  type arg =
    { arg_name : string
    ; arg_type : string
    ; default_value : string option
    }

  type t =
    { name : string
    ; args : arg list
    ; returns : string
    }

  exception Not_a_simple_arg

  let simple_args t =
    try
      List.filter_map t.args ~f:(fun { arg_name; arg_type; default_value } ->
        let simple_type =
          match String.lowercase arg_type with
          | "bool" -> Some `bool
          | "int64_t" -> Some `int64_t
          | "double" -> Some `double
          | "tensor" -> Some `tensor
          | arg_type ->
            if String.is_prefix arg_type ~prefix:"intlist"
            then Some `intlist
            else if Option.is_some default_value then None
            else raise Not_a_simple_arg
        in
        Option.map simple_type ~f:(fun simple_type -> arg_name, simple_type)
      )
      |> Option.some
    with
    | Not_a_simple_arg -> None

  let c_arg_string args =
    List.map args ~f:(fun (arg_name, arg_type) ->
      match arg_type with
      | `intlist ->
        Printf.sprintf "int *%s_data, int %s_len" arg_name arg_name
      | otherwise ->
        let simple_type_cstring =
          match otherwise with
          | `bool -> "int"
          | `int64_t -> "int64_t"
          | `double -> "double"
          | `tensor -> "tensor"
          | `intlist -> assert false
        in
        Printf.sprintf "%s %s" simple_type_cstring arg_name)
    |> String.concat ~sep:", "
end

let read_yaml filename =
  let funcs =
    In_channel.with_file filename ~f:In_channel.input_all
    |> Yaml.of_string_exn
    |> extract_list
    |> List.map ~f:(fun yaml ->
      let map = extract_map yaml in
      let func =
        match Map.find_exn map "func" with
        | [] -> assert false
        | [func] -> extract_string func
        | _ :: _ :: _ -> yaml_error yaml ~msg:"multiple func"
      in
      func, Map.find map "variants" |> Option.value ~default:[])
  in
  printf "Read %s, got %d functions.\n%!" filename (List.length funcs);
  List.filter_map funcs ~f:(fun (func, variants) ->
    let has_function =
      match variants with
      | [] -> true
      | variants -> List.exists variants ~f:(contains_string ~str:"function")
    in
    if has_function
    then
      Option.bind (String.substr_index func ~pattern:"->") ~f:(fun arrow_index ->
        let lhs = String.prefix func arrow_index |> String.strip in
        let returns = String.drop_prefix func (arrow_index + 2) |> String.strip in
        let func_name, args = String.lsplit2_exn lhs ~on:'(' in
        assert (Char.(=) args.[String.length args - 1] ')');
        let args = String.drop_suffix args 1 in
        (* Remove args that contain a std::array<> because of the extra commas... *)
        if String.is_substring args ~substring:"std::" || String.is_empty args
        then None
        else
          let args =
            String.split args ~on:','
            |> List.filter_map ~f:(fun arg ->
              let arg = String.strip arg in
              if String.(=) arg "*"
              then None
              else
                let arg, default_value =
                  match String.split arg ~on:'=' with
                  | [arg] -> String.strip arg, None
                  | [arg; default_value] -> String.strip arg, Some (String.strip default_value)
                  | _ -> Printf.sprintf "unexpected arg format %s" arg |> failwith
                in
                match String.rsplit2 arg ~on:' ' with
                | Some (arg_type, arg_name) -> Some { Function.arg_name; arg_type; default_value }
                | None ->
                  printf "Unhandled argument format for %s: <%s>.\n%!" func_name arg;
                  None
            )
          in
          Some { Function.name = func_name; args; returns })
    else None
  )

let p out_channel s =
  Printf.ksprintf (fun line ->
    Out_channel.output_string out_channel line;
    Out_channel.output_char out_channel '\n') s

let write_cpp funcs filename =
  Out_channel.with_file (filename ^ ".cpp.h") ~f:(fun out_cpp ->
    Out_channel.with_file (filename ^ ".h") ~f:(fun out_h ->
      let pc s = p out_cpp s in
      let ph s = p out_h s in
      pc "";
      pc "// THIS FILE IS AUTOMATICALLY GENERATED, DO NOT EDIT BY HAND!";
      pc "";
      ph "";
      ph "// THIS FILE IS AUTOMATICALLY GENERATED, DO NOT EDIT BY HAND!";
      ph "";
      Map.iteri funcs ~f:(fun ~key:exported_name ~data:func ->
        let { Function.name; returns; _ } = func in
        match Function.simple_args func with
        | None -> ()
        | Some args ->
          if String.(=) returns "Tensor" && Char.(<>) name.[0] '_' && not (Set.mem unsupported_functions name)
          then begin
            let c_arg_string = Function.c_arg_string args in
            let arg_names =
              List.map args ~f:(fun (arg_name, arg_type) ->
                match arg_type with
                | `tensor -> "*" ^ arg_name
                | `bool -> "(bool)" ^ arg_name
                | `intlist -> Printf.sprintf "of_carray(%s_data, %s_len)" arg_name arg_name
                | _ -> arg_name)
              |> String.concat ~sep:", "
            in
            pc "tensor atg_%s(%s) {" exported_name c_arg_string;
            pc "  PROTECT(";
            pc "    return new torch::Tensor(torch::%s(%s));" name arg_names;
            pc "  )";
            pc "}";
            pc "";
            ph "tensor atg_%s(%s);" exported_name c_arg_string;
          end;
      )
    )
  )

let run ~yaml_filename ~cpp_filename =
  let funcs = read_yaml yaml_filename in
  printf "Generating code for %d functions.\n%!" (List.length funcs);
  (* Generate some unique names for overloaded functions. *)
  let funcs =
    List.filter_map funcs ~f:(fun func ->
      if Function.simple_args func |> Option.is_some
      then Some (func.name, func)
      else None)
    |> Map.of_alist_multi (module String)
    |> Map.to_alist
    |> List.concat_map ~f:(fun (name, funcs) ->
      match funcs with
      | [] -> assert false
      | [ func ] -> [ name, func ]
      | funcs ->
        List.mapi funcs ~f:(fun i func ->
          Printf.sprintf "%s%d" name (i+1), func)
      )
    |> Map.of_alist_exn (module String)
  in
  write_cpp funcs cpp_filename

let () =
  run
    ~yaml_filename:"data/native_functions.yaml"
    ~cpp_filename:"src/wrapper/torch_api_generated"
