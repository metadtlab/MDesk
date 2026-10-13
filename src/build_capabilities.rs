//! Side-effect-free build verification using existing FFI DATA values.
//! Stable C ABI for build tools; does not initialize a session or probe devices.

#[no_mangle]
pub extern "C" fn mdesk_build_capabilities_v1() -> u32 {
    let hwcodec = crate::flutter_ffi::main_has_hwcodec().0;
    let vram = crate::flutter_ffi::main_has_vram().0;
    let texture = crate::flutter_ffi::main_has_gpu_texture_render().0;
    (hwcodec as u32) | ((vram as u32) << 1) | ((texture as u32) << 2)
}
