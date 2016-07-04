open OUnit2

let body_string =
  String.concat "\r\n"
    [ {|--------------------------1605451f456c9a1a|}
    ; {|Content-Disposition: form-data; name="a"|}
    ; {||}
    ; {|b|}
    ; {|--------------------------1605451f456c9a1a|}
    ; {|Content-Disposition: form-data; name="c"|}
    ; {||}
    ; {|d|}
    ; {|--------------------------1605451f456c9a1a|}
    ; {|Content-Disposition: form-data; name="upload"; filename="testfile"|}
    ; {|Content-Type: application/octet-stream|}
    ; {||}
    ; {|testfilecontent|}
    ; {||}
    ; {|--------------------------1605451f456c9a1a--|}
    ]

let test_parse ctxt =
  let body = body_string in
  let content_type = "multipart/form-data; boundary=------------------------1605451f456c9a1a" in
  let stream = Lwt_stream.of_list [body] in
  let thread =
    let%lwt parts_stream = Multipart.parse_stream ~stream ~content_type in
    let%lwt parts = Multipart.get_parts parts_stream in
    assert_equal (`String "b") (Multipart.StringMap.find "a" parts);
    assert_equal (`String "d") (Multipart.StringMap.find "c" parts);
    match Multipart.StringMap.find "upload" parts with
    | `String _ -> assert_failure "expected a file"
    | `File file ->
      begin
        assert_equal ~ctxt ~printer:[%show: string] "upload" (Multipart.file_name file);
        assert_equal ~ctxt "application/octet-stream" (Multipart.file_content_type file);
        let%lwt file_chunks = Lwt_stream.to_list (Multipart.file_stream file) in
        assert_equal ~ctxt "testfilecontent" (String.concat "" file_chunks);
        Lwt.return_unit
      end
  in
  Lwt_main.run thread

let test_split ctxt =
  let in_stream =
    Lwt_stream.of_list
      [ "ABCD"
      ; "EFap"
      ; "ple"
      ; "ABCDEFor"
      ; "angeABC"
      ; "HHpl"
      ; "umABCDEFkiwi"
      ; "ABCDEF"
      ]
  in
  let expected =
    [ ["ap" ; "ple"]
    ; ["or"; "ange"; "ABCHHpl"; "um"]
    ; ["kiwi"]
    ; []
    ]
  in
  let stream = Multipart.align in_stream "ABCDEF" in
  Lwt_main.run (
    let%lwt streams = Lwt_stream.to_list stream in
    let%lwt result = Lwt_list.map_s Lwt_stream.to_list streams in
    assert_equal
      ~ctxt
      ~printer:[%show: string list list]
      expected
      result;
    Lwt.return_unit
  )

let test_format ctxt =
  let open Multipart in
  let parts =
    [ make_part ~name:"a" ~value:"b" ()
    ; make_part ~name:"c" ~value:"d" ()
    ; make_part ~name:"upload" ~filename:"testfile" ~content_type:"application/octet-stream" ~value:"testfilecontent\r\n" ()
    ]
  in
  let text = format_multipart_form_data ~parts ~boundary:"------------------------1605451f456c9a1a" in
  assert_equal ~ctxt text body_string

let suite =
  "multipart-form-data" >:::
    [ "parse"  >:: test_parse
    ; "split"  >:: test_split
    ; "format" >:: test_format
    ]

let _ = run_test_tt_main suite
