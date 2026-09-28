# typed: strict
# frozen_string_literal: true

require_relative "command"

module Dev
  # A dev.yml `commands:` entry that nests further `commands:`. Pure data,
  # the parse-side counterpart of CommandGroup: the manifest carries this,
  # and CommandRepository resolves it — merged child by child with any
  # builtin group of the same name — into the CommandGroup the tree serves.
  # Not a Command itself, for the same reason OverriddenCommand is not
  # parsed: what the tree serves is decided at assembly, not at parse.
  class ProjectCommandGroup
    extend T::Sig
    extend T::Helpers
    final!

    sig(:final) { returns(String) }
    attr_reader :desc

    # The leaf the bare invocation runs (`run:` beside `commands:`), if any.
    sig(:final) { returns(T.nilable(ProjectCommand)) }
    attr_reader :own

    # The nested entries, in declaration order.
    sig(:final) { returns(T::Hash[String, T.any(ProjectCommand, ProjectCommandGroup)]) }
    attr_reader :children

    sig(:final) do
      params(
        children: T::Hash[String, T.any(ProjectCommand, ProjectCommandGroup)],
        desc: String,
        own: T.nilable(ProjectCommand),
        hidden: T::Boolean,
      ).void
    end
    def initialize(children:, desc: "(no description)", own: nil, hidden: false)
      @children = T.let(children.freeze, T::Hash[String, T.any(ProjectCommand, ProjectCommandGroup)])
      @desc = desc
      @own = own
      @hidden = hidden
    end

    sig(:final) { returns(T::Boolean) }
    def hidden? = @hidden

    sig(:final) { params(other: Object).returns(T::Boolean) }
    def ==(other)
      return false unless other.is_a?(ProjectCommandGroup)

      @children == other.children && @desc == other.desc && @own == other.own && @hidden == other.hidden?
    end

    sig(:final) { params(other: Object).returns(T::Boolean) }
    def eql?(other)
      self == other
    end

    sig(:final) { returns(Integer) }
    def hash
      [@children, @desc, @own, @hidden].hash
    end
  end

  # What a dev.yml `commands:` entry parses to: a leaf or a group.
  ProjectNode = T.type_alias { T.any(ProjectCommand, ProjectCommandGroup) }
end
