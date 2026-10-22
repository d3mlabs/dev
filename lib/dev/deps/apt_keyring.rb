# typed: strict
# frozen_string_literal: true

module Dev
  module Deps
    # What apt accepts as a `Signed-By:` keyring file, and how to produce it
    # from a vendor's published key.
    #
    # apt's loader (apt-pkg/contrib/gpgv.cc, apt >= 2.9 / Ubuntu 25.04+)
    # picks the parser by file extension: a `.asc` file is read as ASCII
    # armor; any other name must hold a binary OpenPGP public-key packet
    # (first byte 0x98, 0x99 or 0xC6). Anything else is "ignored as the file
    # has an unsupported filetype", which leaves the repository unsigned and
    # fails `apt-get update`. Older apt sniffed the content, which is why an
    # armored key saved as `.key` worked on noble and broke on resolute.
    #
    # Vendors publish armored keys (WineHQ, Docker) and their `.sources`
    # files name a `.key` path — their instructions dearmor with `gpg`. dev
    # does the same without gpg: armor is base64 between a blank line and
    # the `=CRC` line, exactly what apt itself decodes for `.asc`.
    module AptKeyring
      extend T::Sig

      # The fetched key cannot be written at this path in a form apt reads.
      class UnsupportedFormatError < StandardError; end

      ARMOR_HEADER = "-----BEGIN PGP PUBLIC KEY BLOCK-----"
      ARMOR_FOOTER = "-----END"
      ARMORED_EXTENSION = ".asc"
      # Leading byte of an OpenPGP public-key packet: old format up to 255
      # octets, old format up to 65535 octets, new format any length.
      PACKET_LEADING_BYTES = T.let(["\x98".b, "\x99".b, "\xC6".b].freeze, T::Array[String])

      class << self
        extend T::Sig

        # The bytes to write at +path+ for the key fetched as +fetched+.
        #
        # @param path [String] the keyring path apt will read (its extension decides the form)
        # @param fetched [String] the key as published: armored text or binary
        # @return [String] +fetched+ as-is when apt reads it there, else the dearmored packet
        # @raise [UnsupportedFormatError] when no form apt reads at +path+ can be made of +fetched+
        sig { params(path: String, fetched: String).returns(String) }
        def content_for(path, fetched)
          if armored_path?(path)
            unless armored?(fetched)
              raise UnsupportedFormatError,
                "#{path}: apt reads a .asc keyring as ASCII armor, and the key fetched for it is not armored"
            end
            fetched
          elsif armored?(fetched)
            dearmor(fetched, path)
          elsif packet?(fetched)
            fetched
          else
            raise UnsupportedFormatError,
              "#{path}: the fetched key is neither an armored PGP public key block nor a binary OpenPGP key packet"
          end
        end

        # Whether apt would read the key at +path+ holding +bytes+ — the
        # same test its loader applies, so the probe and the install agree.
        #
        # @param path [String]
        # @param bytes [String] the file's content
        # @return [Boolean]
        sig { params(path: String, bytes: String).returns(T::Boolean) }
        def accepted?(path, bytes)
          armored_path?(path) ? armored?(bytes) : packet?(bytes)
        end

        private

        sig { params(path: String).returns(T::Boolean) }
        def armored_path?(path)
          path.end_with?(ARMORED_EXTENSION)
        end

        sig { params(bytes: String).returns(T::Boolean) }
        def armored?(bytes)
          bytes.b.lstrip.start_with?(ARMOR_HEADER)
        end

        sig { params(bytes: String).returns(T::Boolean) }
        def packet?(bytes)
          first = bytes.b[0, 1]
          !first.nil? && PACKET_LEADING_BYTES.include?(first)
        end

        # apt's own walk: header, blank line, base64 lines (skipping the `=CRC`
        # line and anything starting with `-`), footer. Without a footer the
        # block is incomplete and refused rather than half-decoded.
        #
        # @param text [String] armored key
        # @param path [String] for the error message
        # @return [String] the binary packet
        # @raise [UnsupportedFormatError] malformed or truncated armor
        sig { params(text: String, path: String).returns(String) }
        def dearmor(text, path)
          state = T.let(:before_header, Symbol)
          base64 = +""
          text.each_line do |raw|
            line = raw.strip
            if line.start_with?(ARMOR_HEADER)
              state = :headers
            elsif state == :headers && line.empty?
              state = :body
            elsif line.start_with?(ARMOR_FOOTER)
              state = :done
              break
            elsif state == :body && !line.empty? && !line.start_with?("=", "-")
              base64 << line
            end
          end
          raise UnsupportedFormatError, "#{path}: the fetched key's PGP armor is truncated (no END line)" unless state == :done

          packet = base64.unpack1("m").to_s.b
          raise UnsupportedFormatError, "#{path}: the fetched key's PGP armor holds no public-key packet" unless packet?(packet)

          packet
        end
      end
    end
  end
end
