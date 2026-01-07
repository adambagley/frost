#    Copyright 2026 Two Sigma Open Source, LLC
#
#    Licensed under the Apache License, Version 2.0 (the "License");
#    you may not use this file except in compliance with the License.
#    You may obtain a copy of the License at
#
#        http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS,
#    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#    See the License for the specific language governing permissions and
#    limitations under the License.

"""Custom exceptions for verification errors.

Exceptions
==========

This module defines a hierarchy of exception types for different verification
failure scenarios, providing better error categorization and handling.
"""


class VerificationError(Exception):
    """Base exception for all verification-related failures.

    All verification-specific exceptions inherit from this base class,
    allowing callers to catch all verification errors with a single handler.
    """

    pass


class RegisterAccessError(VerificationError):
    """Invalid register access attempt.

    Raised when attempting to access a register outside the valid range (x0-x31)
    or when trying to write to x0 (which is hardwired to zero).
    """

    pass


class MemoryAccessError(VerificationError):
    """Invalid memory access attempt.

    Raised when attempting to access memory outside the valid address space
    or when memory operations would exceed allocated memory bounds.
    """

    pass


class AlignmentError(VerificationError):
    """Memory alignment violation.

    Raised when memory access violates alignment requirements:
    - Halfword (2-byte) accesses must be 2-byte aligned
    - Word (4-byte) accesses must be 4-byte aligned
    """

    def __init__(
        self,
        message: str,
        address: int | None = None,
        required_alignment: int | None = None,
    ):
        """Initialize alignment error with context.

        Args:
            message: Error description
            address: The misaligned address that caused the error
            required_alignment: Required alignment in bytes (2 or 4)
        """
        super().__init__(message)
        self.address = address
        self.required_alignment = required_alignment


class CoverageError(VerificationError):
    """Insufficient instruction coverage.

    Raised when instruction coverage doesn't meet minimum thresholds,
    indicating that some instructions weren't tested adequately.
    """

    def __init__(self, message: str, failed_instructions: list[str] | None = None):
        """Initialize coverage error with failed instruction list.

        Args:
            message: Error description
            failed_instructions: List of instructions that didn't meet coverage threshold
        """
        super().__init__(message)
        self.failed_instructions = failed_instructions or []


class InstructionEncodingError(VerificationError):
    """Invalid instruction encoding.

    Raised when attempting to encode an instruction with invalid parameters,
    such as out-of-range immediates or invalid register indices.
    """

    pass


class MismatchError(VerificationError):
    """Hardware-software mismatch detected.

    Raised when hardware behavior doesn't match software model expectations,
    such as register file mismatches, PC mismatches, or memory write mismatches.
    """

    def __init__(
        self,
        message: str,
        expected_value: int | None = None,
        actual_value: int | None = None,
        cycle: int | None = None,
    ):
        """Initialize mismatch error with comparison context.

        Args:
            message: Error description
            expected_value: Expected value from software model
            actual_value: Actual value from hardware
            cycle: Simulation cycle when mismatch occurred
        """
        super().__init__(message)
        self.expected_value = expected_value
        self.actual_value = actual_value
        self.cycle = cycle
