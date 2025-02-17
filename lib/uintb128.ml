type t = Bytes.t

exception Overflow

let zero () = Bytes.make 16 '\x00'
let min_int () = zero ()
let max_int () = Bytes.make 16 '\xff'
let equal = Bytes.equal
let compare = Bytes.compare

let is_hex_char = function
  | 'a' .. 'f' | '0' .. '9' | 'A' .. 'Z' -> true
  | _ -> false

let int_of_hex_char c =
  match c with
  | '0' .. '9' -> Char.code c - 48
  | 'a' .. 'f' -> Char.code c - 87
  | 'A' .. 'F' -> Char.code c - 55
  | _ -> invalid_arg "char is not a valid hex digit"

(* TODO use Bytes.copy to make it thread safe? *)
let foldi_right2 f a x y =
  for i = 15 downto 0 do
    let x' = Bytes.get_uint8 x i in
    let y' = Bytes.get_uint8 y i in
    f i a x' y'
  done;
  a

(* TODO allow strings shorter than 32 characters. add 0 from left for padding. *)
let of_string_exn s =
  if String.length s <> 32 && String.for_all is_hex_char s then
    invalid_arg "not 32 chars long or invalid hex chars"
  else
    let b = zero () in
    let i = ref 31 in
    let j = ref 15 in
    while !i >= 0 do
      let x = int_of_hex_char (String.get s !i) in
      let y = int_of_hex_char (String.get s (!i - 1)) in
      Bytes.set_uint8 b !j ((y lsl 4) + x);
      i := !i - 2;
      j := !j - 1
    done;
    b

let v = of_string_exn
let of_string s = try Some (of_string_exn s) with Invalid_argument _ -> None

(* TODO
   - use Bytes.copy for thread-safety??
   - ommit leading zeroes by using for upto
*)
let to_string b =
  let l = ref [] in
  for i = 15 downto 0 do
    l := Printf.sprintf "%.2x" (Bytes.get_uint8 b i) :: !l
  done;
  String.concat "" !l

let pp ppf t = Format.fprintf ppf "uintb128 = %s" (to_string t)

let add_exn x y =
  let a, carry =
    foldi_right2
      (fun i (a, carry) x' y' ->
        let sum = x' + y' + !carry in
        if sum >= 256 then (
          carry := 1;
          Bytes.set_uint8 a i (sum - 256))
        else (
          carry := 0;
          Bytes.set_uint8 a i sum))
      (zero (), ref 0)
      x y
  in
  if !carry <> 0 then raise Overflow else a

let add x y = try Some (add_exn x y) with Overflow -> None

let sub_exn x y =
  if Bytes.compare x y = -1 then invalid_arg "y is larger than x"
  else
    let a, carry =
      foldi_right2
        (fun i (a, carry) x' y' ->
          if x' < y' then (
            Bytes.set_uint8 a i (256 + x' - y' - !carry);
            carry := 1)
          else (
            Bytes.set_uint8 a i (x' - y' - !carry);
            carry := 0))
        (zero (), ref 0)
        x y
    in
    if !carry <> 0 then raise Overflow else a

let sub x y =
  try Some (sub_exn x y) with Overflow -> None | Invalid_argument _ -> None

let logand x y =
  foldi_right2 (fun i a x y -> Bytes.set_uint8 a i (x land y)) (zero ()) x y

let logor x y =
  foldi_right2 (fun i a x y -> Bytes.set_uint8 a i (x lor y)) (zero ()) x y

let logxor x y =
  foldi_right2 (fun i a x y -> Bytes.set_uint8 a i (x lxor y)) (zero ()) x y

let lognot x =
  let b = zero () in
  Bytes.iteri (fun i _ -> Bytes.set_uint8 b i (lnot (Bytes.get_uint8 x i))) x;
  b

(* add Byte.t for low-level bit fiddling? *)

(* Make a sum of all bits set, starting from the least significant bit (LSB)
   up to bit poisition n.

   [n] has to be within the range of 1 and 8.

   TODO there must be an easier way :-)
*)
let make_lsb_bitmask n =
  if n <= 0 || n > 8 then invalid_arg "out of bounds"
  else
    let rec aux n' =
      if n' = 0. then 1. else Float.pow 2. n' +. aux (n' -. 1.)
    in
    int_of_float @@ aux (float_of_int (n - 1))

(* Extract the value, starting form the LSB up to bit position [n] *)
let get_lsbits n x =
  assert (n > 0 || n <= 8);
  x land make_lsb_bitmask n

let set_bit i x =
  assert (i >= 0 && i <= 7);
  x lor (1 lsl i)

let is_bit_set i x =
  assert (i >= 0 && i <= 7);
  x land (1 lsl i) <> 0

(* Set value [x] in [y]'s [n] MSB bits

   TODO bounds checking to ensure values stay
   within 0x00 - 0xff

   x <- 0b0000_0111
   n <- 3
   y <- 0b0000_1001

   ->   0b1110_1001
          ^^^
*)
let set_msbits n x y =
  if n < 0 || n > 8 then raise (Invalid_argument "n must be >= 0 && <= 8")
  else if n = 0 then y
  else if n = 8 then x
  else (x lsl (8 - n)) lor y

(* Returns a tuple of how many bytes and how many subsequent
   bits after that need to be shifted.

   Shift by 19 bits results in (2, 3): Shift by 2 bytes, then by 3 bits
*)
let get_bitshift_counts n =
  assert (n >= 0 && n <= 128);
  if n = 0 then (0, 0) else (n / 8, n mod 8)

let shift_right n x =
  match n with
  | 0 -> x
  | 128 -> zero ()
  | n when n > 0 && n < 128 ->
      let b = zero () in
      let shift_bytes, shift_bits = get_bitshift_counts n in
      (if shift_bits = 0 then
       for i = 0 to 15 - shift_bytes do
         let x' = Bytes.get_uint8 x i in
         Bytes.set_uint8 b (i + shift_bytes) x'
       done
      else
        let carry = ref 0 in
        for i = 0 to 15 - shift_bytes do
          let x' = Bytes.get_uint8 x i in
          let new_carry = get_lsbits shift_bits x' in
          let shifted_value = x' lsr shift_bits in
          let new_value =
            shifted_value lor set_msbits shift_bits !carry shifted_value
          in
          Bytes.set_uint8 b (i + shift_bytes) new_value;
          carry := new_carry
        done);
      b
  | _ -> raise (Invalid_argument "n must be >= 0 && <= 128")
