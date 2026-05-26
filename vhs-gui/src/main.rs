mod app;
mod capture;
mod config;
mod library;
mod mpv_view;

fn main() -> eframe::Result {
    let options = eframe::NativeOptions {
        renderer: eframe::Renderer::Glow,
        viewport: egui::ViewportBuilder::default()
            .with_title("vhs-gui")
            .with_inner_size([1280.0, 800.0]),
        ..Default::default()
    };
    eframe::run_native(
        "vhs-gui",
        options,
        Box::new(|cc| Ok(Box::new(app::App::new(cc)?))),
    )
}
