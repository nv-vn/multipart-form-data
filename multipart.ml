module StringMap = Map.Make(String)

type 'a res =
  | Word of 'a
  | Delim
  [@@deriving show]

let ends_with ~suffix s =
  let suffix_length = String.length suffix in
  let s_length = String.length s in
  if s_length >= suffix_length && Str.last_chars s suffix_length = suffix then
    let prefix = Str.first_chars s (s_length - suffix_length) in
    Some (prefix, suffix)
  else
    None

let prefixes s =
  let rec go i =
    if i < 0 then
      []
    else
      (String.sub s 0 i)::go (i-1)
  in
  go (String.length s)

let rec first_matching p = function
  | [] -> None
  | x::xs ->
    begin
      match p x with
      | Some y -> Some y
      | None -> first_matching p xs
    end

let find_common a b =
  let p suffix =
    ends_with ~suffix a
  in
  first_matching p @@ prefixes b

let word = function
  | "" -> []
  | w -> [Word w]

let split_and_process_string ~boundary s =
  let open Lwt.Infix in
  let re = Str.regexp_string boundary in
  let rec go start acc =
    try
      let match_start = Str.search_forward re s start in
      let before = String.sub s start (match_start - start) in
      let new_acc = Delim::(word before)@acc in
      let new_start = match_start + String.length boundary in
      go new_start new_acc
    with
      Not_found -> (word (Str.string_after s start))@acc
  in
  List.rev (go 0 [])

let split s boundary =
  let r = ref None in
  let push v =
    match !r with
    | None -> r := Some v
    | Some _ -> assert false
  in
  let pop () =
    let res = !r in
    r := None;
    res
  in
  let go c0 =
    let c =
      match pop () with
      | Some x -> x ^ c0
      | None -> c0
    in
    let string_to_process = match find_common c boundary with
    | None -> c
    | Some (prefix, suffix) ->
      begin
        push suffix;
        prefix
      end
    in
    Lwt.return @@ split_and_process_string ~boundary string_to_process
  in
  let initial = Lwt_stream.map_list_s go s in
  let final =
    Lwt_stream.flatten @@
    Lwt_stream.from_direct @@ fun () ->
    match pop () with
    | None -> None
    | Some x -> Some (split_and_process_string ~boundary x)
  in
  Lwt_stream.append initial final

let scan f z s =
  let state = ref z in
  let go x =
    let (y, new_state) = f x (!state) in
    state := new_state;
    y
  in
  Lwt_stream.map go s

let until_next_delim s =
  let open Lwt.Infix in
  Lwt_stream.from @@ fun () ->
  Lwt_stream.get s >>= function
  | None
  | Some Delim -> Lwt.return_none
  | Some (Word w) -> Lwt.return_some w

let join s =
  Lwt_stream.filter_map (function
      | Delim -> Some (until_next_delim @@ Lwt_stream.clone s)
      | Word _ -> None
    ) s

let split_join stream boundary =
  join @@ split stream boundary

type header = string
  [@@deriving show]

type part = { p_headers : header list
            ; p_body : string
            }
  [@@deriving show]

let debug m = StringMap.fold (fun k v s ->
    Printf.sprintf "%s => %s\n%s" k ([%show: part] v) s
  ) m ""

type t = part StringMap.t

module List_infix = struct
  let (>>=) xo f = match xo with
    | None -> None
    | Some x -> f x

  let return x = Some x
end

let after_prefix ~prefix str =
  let open List_infix in
  let prefix_len = String.length prefix in
  let str_len = String.length str in
  if (str_len >= prefix_len && Str.first_chars str prefix_len = prefix) then
    return @@ Str.string_after str prefix_len
  else
    None

let extract_boundary content_type =
  after_prefix ~prefix:"multipart/form-data; boundary=" content_type

let unquote s =
  Scanf.sscanf s "%S" @@ (fun x -> x);;

let parse_name s =
  let open List_infix in
  after_prefix ~prefix:"Content-Disposition: form-data; name=" s >>= fun x ->
  return @@ unquote x

let num_parts parts = StringMap.cardinal parts

let get_part m name =
  try
    Some (StringMap.find name m)
  with
  | Not_found -> None

let part_body { p_body } =
  p_body

let part_names m =
  StringMap.fold
    (fun k _ l -> k::l)
    m
    []

let parse_header s =
  s

let non_empty st =
  let open Lwt.Infix in
  Lwt_stream.to_list (Lwt_stream.clone st) >>= fun r ->
  Lwt.return (String.concat "" r <> "")

let get_headers : string Lwt_stream.t Lwt_stream.t -> header list Lwt.t
  = fun lines ->
  let open Lwt.Infix in
  (Lwt_stream.get_while_s non_empty lines) >>= fun header_lines ->
  Lwt_list.map_s (fun header_line_stream ->
      Lwt_stream.to_list header_line_stream >>= fun parts ->
      Lwt.return @@ parse_header @@ String.concat "" parts
    ) header_lines

type stream_part =
  { headers : header list
  ; body : string Lwt_stream.t
  }

let debug_stream_part {body;headers} =
  let open Lwt.Infix in
  Lwt_stream.to_list body >>= fun body_chunks ->
  Lwt.return @@
  Printf.sprintf
    "headers : %s\nbody: %s\n"
    ([%show: header list] headers)
    (String.concat "" body_chunks)

let debug_stream sps =
  let open Lwt.Infix in
  Lwt_list.map_s debug_stream_part sps >>= fun parts ->
  Lwt.return @@ String.concat "--\n" parts

let parse_part chunk_stream =
  let open Lwt.Infix in
  let lines = join @@ split chunk_stream "\r\n" in
  get_headers lines >>= fun headers ->
  let body = Lwt_stream.concat @@ Lwt_stream.clone lines in
  Lwt.return { headers ; body }

let parse_stream ~stream ~content_type =
  let open Lwt.Infix in
  match extract_boundary content_type with
  | None -> Lwt.fail_with "Cannot parse content-type"
  | Some boundary ->
    begin
      let actual_boundary = ("--" ^ boundary) in
      Lwt.return @@ Lwt_stream.map_s parse_part @@ join @@ split stream actual_boundary
    end

let get_name_from_part headers =
  match
    first_matching parse_name headers
  with
  | Some x -> x
  | None -> invalid_arg (Printf.sprintf "get_name_from_part , headers = %s" ([%show: header list] headers))

let s_part_body {body} = body

let s_part_name {headers} = get_name_from_part headers

let parse ~body ~content_type =
  let open Lwt.Infix in
  let stream = Lwt_stream.of_list [body] in
  let thread =
    parse_stream ~stream ~content_type >>= fun stream ->
    Lwt_stream.to_list stream >>= fun parts ->
    Lwt_list.fold_left_s (fun m { headers ; body } ->
        Lwt_stream.to_list body >>= fun body_chunks ->
        let p_body = String.concat "" body_chunks in
        if headers = [] && p_body = "" then
          Lwt.return m
        else
          let name = get_name_from_part headers in
          let part = { p_headers = headers ; p_body } in
          Lwt.return @@ StringMap.add name part m
      ) StringMap.empty parts
  in
  Some (Lwt_main.run thread)