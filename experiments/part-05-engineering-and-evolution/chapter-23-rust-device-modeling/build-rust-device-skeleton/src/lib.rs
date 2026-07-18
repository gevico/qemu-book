// SPDX-License-Identifier: Apache-2.0

#![forbid(unsafe_code)]

const REGISTER_OFFSET: u64 = 0;
const REGISTER_SIZE: u32 = 4;
const RESET_VALUE: u32 = 0x5145_4d55;
const WRITABLE_MASK: u32 = 0x0000_ffff;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AccessError {
    InvalidOffset,
    InvalidSize,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RegisterDevice {
    register: u32,
}

impl Default for RegisterDevice {
    fn default() -> Self {
        Self {
            register: RESET_VALUE,
        }
    }
}

impl RegisterDevice {
    pub fn read(&self, offset: u64, size: u32) -> Result<u32, AccessError> {
        validate_access(offset, size)?;
        Ok(self.register)
    }

    pub fn write(&mut self, offset: u64, size: u32, value: u32) -> Result<(), AccessError> {
        validate_access(offset, size)?;
        self.register = (self.register & !WRITABLE_MASK) | (value & WRITABLE_MASK);
        Ok(())
    }

    pub fn reset(&mut self) {
        self.register = RESET_VALUE;
    }
}

fn validate_access(offset: u64, size: u32) -> Result<(), AccessError> {
    if offset != REGISTER_OFFSET {
        return Err(AccessError::InvalidOffset);
    }
    if size != REGISTER_SIZE {
        return Err(AccessError::InvalidSize);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reset_restores_documented_value() {
        let mut device = RegisterDevice::default();
        device.write(0, 4, 0x1234).unwrap();
        device.reset();
        assert_eq!(device.read(0, 4), Ok(RESET_VALUE));
    }

    #[test]
    fn only_low_half_is_writable() {
        let mut device = RegisterDevice::default();
        device.write(0, 4, 0xffff_1234).unwrap();
        assert_eq!(device.read(0, 4), Ok(0x5145_1234));
    }

    #[test]
    fn bad_offset_is_rejected() {
        let device = RegisterDevice::default();
        assert_eq!(device.read(4, 4), Err(AccessError::InvalidOffset));
    }

    #[test]
    fn bad_size_is_rejected() {
        let mut device = RegisterDevice::default();
        assert_eq!(device.write(0, 2, 1), Err(AccessError::InvalidSize));
    }
}
