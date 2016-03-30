class String
  def to_bool
    return true   if self == true   || self =~ (/(true|t|yes|y|1)$/i)
    return false  if self == false  || self.empty? || self =~ (/(false|f|no|n|0)$/i)
    raise ArgumentError.new("invalid value for Boolean: \"#{self}\"")
  end
end

module Lita
  module Handlers
    class Rsvp < Handler
      ATTENDING = "yes"
      NOT_ATTENDING = "no"
      USERS = "users"

      on :loaded, :define_routes
      on :mark_attending, :mark_attending
      on :mark_not_attending, :mark_not_attending

      Lita.register_handler(self)

      def define_routes payload
        self.class.route /^attending (.+)$/, :set_attending, command: true
        self.class.route /^not attending (.+)$/, :set_not_attending, command: true
        self.class.route /^new event \((.+)\):\s+(.+)$/, :new_event, command: true
      end

      def set_attending response
        robot.trigger :mark_attending, slug: response.matches[0][0], user: response.user, room: response.room
      end

      def set_not_attending response
        robot.trigger :mark_not_attending, slug: response.matches[0][0], user: response.user, room: response.room
      end

      def new_event response
        slug = response.matches[0][0]
        description = response.matches[0][1]

        if redis.exists(full_key(slug))
          response.reply_with_mention "Event already exists!"
        else
          redis.set full_key(slug), description
          redis.set attending_key(slug), 0
          redis.set not_attending_key(slug), 0
          response.reply_with_mention "Event created! Mark that you are attending by stating \"attending #{slug}\""
        end
      end

      def mark_attending payload
        payload[:attending] = true
        set_attendance payload
      end

      def mark_not_attending payload
        payload[:attending] = false
        set_attendance payload
      end

      private

      def set_attendance payload
        payload[:user] = payload[:user].name if payload[:user].class == Lita::User
        # Retrieve existing value, if any
        if redis.exists(full_key(payload[:slug]))
          attending = redis.get full_key([payload[:slug], payload[:user]]).to_bool
          adjust_attendances payload[:slug], attending, payload[:attending]
          redis.set full_key([payload[:slug], payload[:user]]), payload[:attending]
          update_topic payload[:room], payload[:slug]
        end
      end

      def update_topic room, slug
        robot.trigger :appended_topic_position, room: room, position: 0, topic: build_topic(slug)
      end

      def build_topic slug
        desc = redis.get full_key(slug)
        attending = redis.get attending_key(slug)
        not_attending = redis.get not_attending_key(slug)

        "#{desc} -- #{attending} Yes, #{not_attending} No"
      end

      def adjust_attendances slug, old, new
        return if old == new
        old_attending = (redis.get attending_key(slug) || 0).to_i
        old_not_attending = (redis.get not_attending_key(slug) || 0).to_i
        if old == false # Initially not attending, now attending
          old_not_attending = [old_not_attending - 1, 0].max
          old_attending = [old_attending + 1, 0].max
        elsif old == true # Was attending, now not
          old_not_attending = [old_not_attending + 1, 0].max
          old_attending = [old_attending - 1, 0].max
        else # old was null
          old_not_attending = [old_not_attending + 1, 0].max unless new
          old_attending = [old_attending + 1, 0].max if new
        end

        # Store in Redis
        redis.set attending_key(slug), old_attending
        redis.set not_attending_key(slug), old_not_attending
      end

      def full_key key
        key = [key] unless key.class == Array
        key = ["lita-rsvp"].concat key
        key.map {|v| v.to_s.downcase}.join(":")
      end

      def user_key slug, user
        full_key [slug, user]
      end

      def event_key slug
        full key slug
      end

      def attending_key slug
        full_key [slug, ATTENDING]
      end

      def not_attending_key slug
        full_key [slug, NOT_ATTENDING]
      end
    end
  end
end
