# typed: false
# frozen_string_literal: true

# A tiny OpenPGP public key in both forms apt meets: the binary packet and
# the ASCII armor `gpg --armor` prints for it (header, blank line, 64-column
# base64, CRC24 line, footer). Shared by the keyring and apt integration
# tests so the two cannot drift on what "a key" looks like.
module OpenPGPKeyFixture
  # Old-format tag-6 packet with a two-octet length (0x99), then 16 body bytes.
  BINARY = ("\x99\x00\x10" + (0..15).map(&:chr).join).b.freeze

  module_function

  # @param binary [String] packet bytes
  # @return [String] the armored text
  def armored(binary = BINARY)
    crc = [[crc24(binary)].pack("N")[1, 3]].pack("m0")
    body = [binary].pack("m0").scan(/.{1,64}/).join("\n")
    "-----BEGIN PGP PUBLIC KEY BLOCK-----\n\n#{body}\n=#{crc}\n-----END PGP PUBLIC KEY BLOCK-----\n"
  end

  # RFC 4880 §6.1 CRC-24, the checksum on the armor's `=` line.
  #
  # @param bytes [String]
  # @return [Integer]
  def crc24(bytes)
    crc = 0xB704CE
    bytes.each_byte do |b|
      crc ^= b << 16
      8.times do
        crc <<= 1
        crc ^= 0x1864CFB if (crc & 0x1000000).nonzero?
      end
    end
    crc & 0xFFFFFF
  end
end
