use serde_derive::{Deserialize, Serialize};

mod client;
mod server;

#[cfg(target_os = "linux")]
mod linux;
#[cfg(target_os = "macos")]
mod macos;
#[cfg(any(target_os = "windows", target_os = "linux"))]
mod win_linux;
#[cfg(target_os = "windows")]
mod windows;

#[cfg(target_os = "linux")]
pub use linux::is_supported;
#[cfg(target_os = "macos")]
use macos::create_event_loop;
#[cfg(target_os = "windows")]
use windows::create_event_loop;

pub use client::*;
pub use server::*;

#[derive(Debug, Serialize, Deserialize, Clone)]
#[serde(tag = "t", content = "c")]
pub enum CustomEvent {
    Cursor(Cursor),
    Draw(DrawStroke),
    ClearDraw,
    UndoDraw,
    Clear,
    Exit,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
#[serde(tag = "t")]
pub struct Cursor {
    pub x: f32,
    pub y: f32,
    pub argb: u32,
    pub btns: i32,
    pub text: String,
}

/// 드로잉 스트로크 데이터
#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct DrawStroke {
    /// 정규화된 좌표 (0.0 ~ 1.0)
    pub points: Vec<DrawPoint>,
    /// ARGB 색상
    pub argb: u32,
    /// 선 두께
    pub stroke_width: f32,
    /// 도구 타입 (0: pen, 1: highlighter, 2: eraser)
    pub tool: u8,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct DrawPoint {
    pub x: f32,
    pub y: f32,
}
