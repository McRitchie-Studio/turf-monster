# One MCP tool: a name and a description for the model, a JSON Schema for its
# arguments, honest annotations, and the agent API operation it runs.
#
# A tool holds NO rule of the game. It renames arguments (a model reads
# `contest_slug` better than `slug`) and calls the same operation the matching
# /api/v1 endpoint calls (app/services/api/v1/operations). Whether an argument's
# VALUE is acceptable is the operation's answer, in the same words REST uses.
#
# The only checks made here are about the call's shape against this tool's own
# schema: an argument the schema does not have, or a required one left out. A
# model that sends `slug` for `contest_slug` should hear exactly that, not "no
# such resource".
module AgentMcp
  class Tool
    attr_reader :name, :title, :description, :operation

    # arguments: { "argument_name" => { schema:, required:, param: } }
    #   schema    the JSON Schema of the argument, as published
    #   required  listed under the schema's `required`
    #   param     the operation's name for it (default: the argument's own)
    # to_operation: argument names passed to the operation as keywords instead
    #   of params (the idempotency key, which REST reads from a header).
    def initialize(name:, title:, description:, operation:, writes:, arguments: {}, keywords: {},
                   operation_options: {})
      @name = name
      @title = title
      @description = description.squish
      @operation = operation
      @writes = writes
      @arguments = arguments.transform_keys(&:to_s)
      @keywords = keywords.transform_keys(&:to_s)
      @operation_options = operation_options
    end

    # A writing tool is refused for an account on hold or short of the age gate.
    def writes? = @writes

    def input_schema
      {
        type: "object",
        properties: @arguments.transform_values { |argument| argument.fetch(:schema) },
        required: required_arguments,
        additionalProperties: false
      }
    end

    # Every tool reads or writes Turf Monster's own data and nothing else
    # (openWorldHint false). The two writing tools overwrite or spend, so they
    # are marked destructive: a client that asks before a destructive call is
    # doing what the game wants. Both are idempotent for the same arguments:
    # submit_entry because the idempotency key is one of them.
    def annotations
      { title: title, readOnlyHint: !writes?, destructiveHint: writes?, idempotentHint: true, openWorldHint: false }
    end

    def definition(version)
      definition = { name: name }
      definition[:title] = title if Protocol.titles?(version)
      definition.merge(description: description, inputSchema: input_schema, annotations: annotations)
    end

    def call(user:, api_key:, arguments:, writable:)
      check_shape!(arguments)

      params = {}.with_indifferent_access
      keywords = {}
      arguments.each do |argument, value|
        if @keywords.key?(argument)
          keywords[@keywords.fetch(argument)] = value
        else
          params[@arguments.fetch(argument).fetch(:param, argument)] = value
        end
      end
      # A keyword the model left out is still passed, as nil, so the operation
      # is the one that says it is missing.
      @keywords.each_value { |keyword| keywords[keyword] = nil unless keywords.key?(keyword) }

      operation.call(user: user, api_key: api_key, params: params, writable: writable,
                     **@operation_options, **keywords)
    end

    private

    def required_arguments
      @arguments.select { |_, argument| argument[:required] }.keys
    end

    def check_shape!(arguments)
      unknown = arguments.keys - @arguments.keys
      if unknown.any?
        takes = @arguments.any? ? "It takes: #{@arguments.keys.join(', ')}." : "It takes no arguments."
        raise ActionController::BadRequest, "#{name} has no argument named #{unknown.join(', ')}. #{takes}"
      end

      missing = required_arguments.reject { |argument| arguments.key?(argument) && !arguments[argument].nil? }
      # The idempotency key's own message says what it is for; let it speak.
      missing -= @keywords.keys
      raise ActionController::BadRequest, "#{missing.join(', ')} is required." if missing.any?
    end
  end
end
