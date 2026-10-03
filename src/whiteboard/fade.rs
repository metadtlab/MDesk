use std::time::{Duration, Instant};

// Keep this in sync with kWhiteboardStrokeFadeDuration in the Flutter overlay.
const STROKE_FADE_DURATION: Duration = Duration::from_secs(3);

pub(super) struct StrokeFade {
    completed_at: Instant,
}

impl StrokeFade {
    pub(super) fn new() -> Self {
        Self {
            completed_at: Instant::now(),
        }
    }

    pub(super) fn opacity_at(&self, now: Instant) -> f32 {
        let age = now.saturating_duration_since(self.completed_at);
        (1.0 - age.as_secs_f32() / STROKE_FADE_DURATION.as_secs_f32()).clamp(0.0, 1.0)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fades_after_completion_and_expires() {
        let fade = StrokeFade::new();
        let start = fade.completed_at;
        assert_eq!(fade.opacity_at(start), 1.0);
        assert_eq!(fade.opacity_at(start + Duration::from_millis(1500)), 0.5);
        assert_eq!(fade.opacity_at(start + STROKE_FADE_DURATION), 0.0);
        assert_eq!(fade.opacity_at(start + Duration::from_secs(10)), 0.0);
    }

    #[test]
    fn strokes_have_independent_lifetimes() {
        let start = Instant::now();
        let older = StrokeFade {
            completed_at: start,
        };
        let newer = StrokeFade {
            completed_at: start + Duration::from_secs(2),
        };
        let now = start + STROKE_FADE_DURATION;
        assert_eq!(older.opacity_at(now), 0.0);
        assert!((newer.opacity_at(now) - 2.0 / 3.0).abs() < f32::EPSILON);
        assert_eq!(newer.opacity_at(start), 1.0);
    }
}
