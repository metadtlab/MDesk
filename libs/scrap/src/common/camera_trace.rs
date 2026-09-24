//! Low-volume checkpoints written before entering native camera code.
//! Never log frame contents or device identifiers supplied by a driver.
use std::{
    fmt,
    time::{Duration, Instant},
};

pub(super) fn checkpoint(stage: &str, detail: fmt::Arguments<'_>) {
    hbb_common::log::info!(
        "[CameraDiag] pid={} thread={:?} stage={} {}",
        std::process::id(),
        std::thread::current().id(),
        stage,
        detail
    );
    // The desktop file logger uses Direct writes. Flush also covers buffered
    // loggers used by probes; do this at milestones, never for every frame.
    hbb_common::log::logger().flush();
}

pub(super) struct CaptureTrace {
    index: usize,
    started: Instant,
    reported: Instant,
    read_started: bool,
    decoded: bool,
    frames: u64,
    invalid: u64,
    read_errors: u64,
}

impl CaptureTrace {
    pub(super) fn new(index: usize) -> Self {
        Self {
            index,
            started: Instant::now(),
            reported: Instant::now(),
            read_started: false,
            decoded: false,
            frames: 0,
            invalid: 0,
            read_errors: 0,
        }
    }

    pub(super) fn before_read(&mut self) {
        if !self.read_started {
            checkpoint(
                "frame.first_read.begin",
                format_args!("camera={}", self.index),
            );
            self.read_started = true;
        }
        if self.reported.elapsed() >= Duration::from_secs(10) {
            self.summary("capture.sample");
            self.reported = Instant::now();
        }
    }

    pub(super) fn stream(&self, stage: &str) {
        checkpoint(stage, format_args!("camera={}", self.index));
    }

    pub(super) fn received(&mut self, buffer: &nokhwa::Buffer) {
        self.frames += 1;
        if self.frames == 1 {
            checkpoint(
                "frame.first_read.end",
                format_args!(
                    "camera={} width={} height={} format={:?} bytes={} elapsed_ms={}",
                    self.index,
                    buffer.resolution().width(),
                    buffer.resolution().height(),
                    buffer.source_frame_format(),
                    buffer.buffer().len(),
                    self.started.elapsed().as_millis()
                ),
            );
            checkpoint(
                "frame.first_decode.begin",
                format_args!("camera={}", self.index),
            );
        }
    }

    pub(super) fn decoded(&mut self, width: usize, height: usize) {
        if !self.decoded {
            checkpoint(
                "frame.first_decode.ok",
                format_args!(
                    "camera={} width={} height={} invalid_before={} elapsed_ms={}",
                    self.index,
                    width,
                    height,
                    self.invalid,
                    self.started.elapsed().as_millis()
                ),
            );
            self.decoded = true;
        }
    }

    pub(super) fn invalid(&mut self) {
        self.invalid += 1;
        if self.invalid == 1 {
            checkpoint(
                "frame.decode.invalid",
                format_args!("camera={} received={}", self.index, self.frames),
            );
        }
    }

    pub(super) fn read_error(&mut self) {
        self.read_errors += 1;
        if self.read_errors == 1 {
            checkpoint("frame.read.error", format_args!("camera={}", self.index));
        }
    }

    fn summary(&self, stage: &str) {
        checkpoint(
            stage,
            format_args!(
                "camera={} received={} invalid={} read_errors={} decoded_any={} elapsed_ms={}",
                self.index,
                self.frames,
                self.invalid,
                self.read_errors,
                self.decoded,
                self.started.elapsed().as_millis()
            ),
        );
    }
}

impl Drop for CaptureTrace {
    fn drop(&mut self) {
        self.summary("capture.trace.end");
    }
}
