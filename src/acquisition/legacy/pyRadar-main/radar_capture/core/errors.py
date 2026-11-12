class RadarCaptureError(Exception):
    """Base error for offline radar capture tooling."""


class ProfileError(RadarCaptureError):
    """Base error for concept profile operations."""


class ProfileParseError(ProfileError):
    """Raised when a profile or mmWave config cannot be parsed."""


class ProfileGenerateError(ProfileError):
    """Raised when a generated config cannot be produced safely."""


class ProfileValidationError(ProfileError):
    """Raised when validation fails."""


class UnsafeProfileError(ProfileValidationError):
    """Raised when a profile exceeds allowed safety limits."""
