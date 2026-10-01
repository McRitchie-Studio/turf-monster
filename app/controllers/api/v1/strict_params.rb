# Parameter readers that answer in the API's error envelope instead of raising
# a 500 (docs/AGENT_API.md, "Errors").
#
# A query string can carry any SHAPE under any name: `limit[]=1` is an Array,
# `contest[x]=y` a Hash, `%00` a NUL byte. Handed to `to_i` or to a `where`,
# each of those raised deep in Rails or in Postgres and reached the client as
# `internal_error`. Here a parameter is the type its endpoint documents, or the
# request is refused:
#
#   a value that is not what the endpoint takes   400 bad_request
#   a slug that cannot name anything              404 not_found, the same answer
#                                                 as a slug that names nothing
module Api
  module V1
    module StrictParams
      MAX_SLUG_LENGTH = 255
      # Nine digits: comfortably inside a 32-bit integer, so no value that
      # passes can overflow a column or an OFFSET.
      WHOLE_NUMBER = /\A\d{1,9}\z/
      # Ids are bigint; eighteen digits stays inside one.
      ID_FORMAT = /\A[1-9]\d{0,17}\z/

      private

      def bad_request!(message)
        raise ActionController::BadRequest, message
      end

      # A slug from the path or the query, or RecordNotFound.
      def slug_param(name = :slug)
        value = params[name]
        return value if value.is_a?(String) && value.length.between?(1, MAX_SLUG_LENGTH) && !value.include?("\u0000")

        raise ActiveRecord::RecordNotFound
      end

      # nil when the parameter was not sent.
      def whole_number_param(name, minimum: 0)
        value = params[name]
        return nil if value.nil? || value == ""

        value = value.to_s if value.is_a?(Integer)
        unless value.is_a?(String) && value.match?(WHOLE_NUMBER) && value.to_i >= minimum
          bad_request!("#{name} must be a whole number from #{minimum} to 999999999.")
        end
        value.to_i
      end

      # A JSON array of ids: integers, or strings of digits.
      def id_list_param(name)
        value = params[name]
        bad_request!("#{name} is required: an array of ids.") if value.nil?
        bad_request!("#{name} must be an array of ids.") unless value.is_a?(Array) && value.length.between?(1, 100)

        value.map do |id|
          id = id.to_s if id.is_a?(Integer)
          bad_request!("#{name} must be an array of ids.") unless id.is_a?(String) && id.match?(ID_FORMAT)
          id.to_i
        end
      end

      # JSON true, JSON false, or absent (false). Nothing else, the strings
      # "true" and "false" included: the answer decides whether USDC is spent,
      # so it is read only from the one type that cannot be a typo.
      def boolean_param(name)
        value = params[name]
        return false if value.nil?
        return value if [true, false].include?(value)

        bad_request!("#{name} must be the JSON boolean true or false.")
      end
    end
  end
end
