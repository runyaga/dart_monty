fn main() {
    // Ensure macOS dylibs use @rpath instead of absolute build paths.
    // Without this, cargo emits install_name = /full/build/path/libdart_monty_native.dylib
    // which causes dyld failures on consumer machines. See #47.
    let target_os = std::env::var("CARGO_CFG_TARGET_OS").unwrap_or_default();
    if target_os == "macos" {
        println!("cargo:rustc-cdylib-link-arg=-Wl,-install_name,@rpath/libdart_monty_native.dylib");
    }
}
