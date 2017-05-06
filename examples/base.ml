module A = Ctypes.CArray

let get, set = Ctypes.(getf,setf)
let null = Ctypes.null

let ($=) field value str= set str field value
let ( ^ ) = get

let make typ updates =
  let str=Ctypes.make typ in
  List.iter (fun f -> f str) updates;
  str

let layers = Ctypes.allocate_n ~count:0 Ctypes.string
let extensions = Ctypes.allocate_n ~count:0 Ctypes.string

let (<?>) x s = match x with
  | Ok _ -> Format.printf "Success: %s\n" s
  | Error k ->
    Format.eprintf "Error %a: %s @."
      Vk.Result.pp k s; exit 1

let (!) = Ctypes.(!@)
let (~:) = Unsigned.UInt32.of_int
let to_int = Unsigned.UInt32.to_int

let debug fmt = Format.printf ("Debug: " ^^ fmt ^^ "@.")

let info =
  make Vk.instance_create_info
    Vk.Instance_create_info.[
      s_type $= Vk.Structure_type.Instance_create_info;
      p_next $= null;
      flags $= Vk.Instance_create_flags.empty;
      p_application_info $= None;
      enabled_layer_count $= Unsigned.UInt32.of_int 0;
      pp_enabled_layer_names $= layers;
      enabled_extension_count $= Unsigned.UInt32.of_int 0;
      pp_enabled_extension_names $= extensions;
    ]

;; debug "Info created"

let instance = Ctypes.allocate_n Vk.instance 1
;; debug "Instance pointer allocated"

;; Vk.create_instance (Ctypes.addr info) None instance
   <?> "instance"

let instance = !instance

let (+@) = Ctypes.(+@)

let phy_devices =
  let n = 2 in
  let count = Ctypes.(allocate uint32_t) ~:n in
  let devices = Ctypes.(allocate_n Vk.physical_device) n in
  Vk.enumerate_physical_devices instance count devices
  <?>"physical device";
  debug "Number of devices: %d \n" (to_int !count);
  Array.init (to_int !count) (fun i -> !(devices +@ i) )

let property device =
  let p = Ctypes.make Vk.physical_device_properties in
  debug "Device properties acquisition";
  Vk.get_physical_device_properties device (Ctypes.addr p);
  debug "Device properties acquired";
  p

let to_string carray =
  String.init (A.length carray)
    (fun n -> A.get carray n)

let print_property device =
  let p = property device in
  Format.printf "Device: %s\n"
   (to_string @@ p ^ Vk.Physical_device_properties.device_name)

;; Array.iter print_property phy_devices

let phydevice = phy_devices.(0)

let nullptr typ = Ctypes.(coerce (ptr void) (ptr typ) null)

let queue_family_properties =
  let n = Ctypes.(allocate uint32_t) ~:0 in
  Vk.get_physical_device_queue_family_properties
    phydevice n (nullptr Vk.Queue_family_properties.t);
  let properties =
    Ctypes.allocate_n Vk.Queue_family_properties.t (to_int !n) in
  Vk.get_physical_device_queue_family_properties
    phydevice n properties;
  Array.init (to_int !n) (fun n -> !(properties +@ n))

let print_queue_property ppf property =
  Format.fprintf ppf "Queue flags: %a \n" Vk.Queue_flags.pp
    (property ^ Vk.Queue_family_properties.queue_flags)

;; Array.iter (print_queue_property Format.std_formatter)
  queue_family_properties
(*
let device =
  let d = Ctypes.allocate_n Vk.Device.t 1 in
  let info =
    let open Vk.Device_create_info in
    make t []
  Vk.create_device phy_devices.(0)
*)
;; debug "End"