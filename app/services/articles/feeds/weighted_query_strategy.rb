module Articles
  module Feeds
    # @api private
    #
    # This is an experimental object that we're refining to be a
    # competetor to the existing feed strategies.
    #
    # @note One possible short-coming is that the query does not
    #   account for the Forem's administrators.
    # @note For those considering extending this, be very mindful of
    #   SQL injection.
    class WeightedQueryStrategy
      # This constant defines the allowable relevance scoring methods.
      #
      # A scoring method should be a SQL fragement that produces a
      # value between 0 and 1.  The closer the value is to 1, the more
      # relevant the article is for the given user.  Note: the values
      # are multiplicative.  Make sure to consider if you want a 0
      # multiplier for your score.
      #
      # In addition, as part of initialization, the caller can
      # configure each of the scoring methods :cases and :fallback.
      #
      # Each scoring method has three keys:
      #
      # - clause: The SQL clause statement; note: there exists a
      #           coupling between the clause and the SQL fragments
      #           that join the various tables.
      #
      # - cases: An Array of Arrays, the first value is what matches
      #          the clause, the second value is the multiplicative
      #          factor.
      #
      # - fallback: When no case is matched use this factor.
      #
      # - requires_user: Does this scoring method require a given
      #                  user.  If not, don't use it if we don't have
      #                  a nil user.
      SCORING_METHOD_CONFIGURATIONS = {
        # Weight to give based on the age of the article.
        daily_decay_factor: {
          clause: "(current_date - published_at::date)",
          cases: [
            [0, 1], [1, 0.95], [2, 0.9],
            [3, 0.85], [4, 0.8], [5, 0.75],
            [6, 0.7], [7, 0.65], [8, 0.6],
            [9, 0.55], [10, 0.5], [11, 0.4],
            [12, 0.3], [13, 0.2], [14, 0.1]
          ],
          fallback: 0,
          requires_user: false
        },
        # Weight to give for the number of comments on the article
        # from other users that the given user follows.
        comment_count_by_those_followed_factor: {
          clause: "COUNT(comments_by_followed.id)",
          cases: [[0, 0.95], [1, 0.98], [2, 0.99]],
          fallback: 0.93,
          requires_user: true
        },
        # Weight to give to the number of comments on the article.
        comments_count_factor: {
          clause: "articles.comments_count",
          cases: [[0, 0.9], [1, 0.94], [2, 0.95], [3, 0.98], [4, 0.999]],
          fallback: 1,
          requires_user: false
        },
        # Weight to give based on the difference between experience
        # level of the article and given user.
        experience_factor: {
          clause: "ROUND(ABS(articles.experience_level_rating - (SELECT
              (CASE
                 WHEN experience_level IS NULL THEN :default_user_experience_level
                 ELSE experience_level END ) AS user_experience_level
              FROM users_settings WHERE users_settings.user_id = :user_id
            )))",
          cases: [[0, 1], [1, 0.98], [2, 0.97], [3, 0.96], [4, 0.95], [5, 0.94]],
          fallback: 0.93,
          requires_user: true
        },
        # Weight to give when the given user follows the article's
        # author.
        following_author_factor: {
          clause: "COUNT(followed_user.follower_id)",
          cases: [[0, 0.8], [1, 1]],
          fallback: 1,
          requires_user: true
        },
        # Weight to give to the when the given user follows the
        # article's organization.
        following_org_factor: {
          clause: "COUNT(followed_org.follower_id)",
          cases: [[0, 0.95], [1, 1]],
          fallback: 1,
          requires_user: true
        },
        # Weight to give an article based on it's most recent comment.
        latest_comment_factor: {
          clause: "(current_date - MAX(comments.created_at)::date)",
          cases: [[0, 1], [1, 0.9988]],
          fallback: 0.988,
          requires_user: false
        },
        # Weight to give for the number of intersecting tags the given
        # user follows and the article has.
        matching_tags_factor: {
          clause: "COUNT(followed_tags.follower_id)",
          cases: [[0, 0.4], [1, 0.9]],
          fallback: 1,
          requires_user: true
        },
        # Weight to give for the number of reactions on the article.
        reactions_factor: {
          clause: "articles.reactions_count",
          cases: [[0, 0.9988], [1, 0.9988], [2, 0.9988], [3, 0.9988]],
          fallback: 1,
          requires_user: false
        },
        # Weight to give based on spaminess of the article.
        spaminess_factor: {
          clause: "articles.spaminess_rating",
          cases: [[0, 1]],
          fallback: 0.05,
          requires_user: false
        }
      }.freeze

      DEFAULT_USER_EXPERIENCE_LEVEL = 5

      # @param user [User] who are we querying for?
      # @param number_of_articles [Integer] how many articles are we
      #   returning
      # @param page [Integer] what is the pagination page
      # @param tag [String, nil] this isn't implemented in other feeds
      #   so we'll see
      # @param config [Hash<Symbol, Object>] a list of configurations,
      #   see {#initialize} implementation details.
      # @option config [Array<Symbol>] :scoring_configs
      #   allows for you to configure which methods you want to use.
      #   This is most relevant when running A/B testing.
      #
      # @todo I envision that we will tweak the factors we choose, so
      #   those will likely need some kind of structured consideration.
      def initialize(user: nil, number_of_articles: 50, page: 1, tag: nil, **config)
        @user = user
        @number_of_articles = number_of_articles.to_i
        @page = page.to_i
        @tag = tag
        @default_user_experience_level = config.fetch(:default_user_experience_level) { DEFAULT_USER_EXPERIENCE_LEVEL }
        @scoring_configs = config.fetch(:scoring_configs) { default_scoring_configs }
        configure!(scoring_configs: @scoring_configs)
      end

      # The goal of this query is to generate a list of articles that
      # are relevant to the user's interest.
      #
      # First we give a score to an article based on it's publication
      # date.  The max possible score is 1.
      #
      # Then we begin multiplying that score by numbers between 0 and
      # 1.  The closer that multiplier is to 1 the "more relevant"
      # that factor is to the user.
      #
      # @todo Need to impliment a common interface for the
      # Articles::Feeds for both Basic and LargeForemExperimental as
      # well as the signed in and not signed in cases.
      def call
        if @user.nil?
          Article.find_by_sql([
                                sql_for_nil_user,
                                {
                                  number_of_results: @number_of_articles.to_i
                                },
                              ])
        else
          Article.find_by_sql([
                                sql_for_existing_user,
                                {
                                  user_id: @user.id,
                                  number_of_results: @number_of_articles.to_i,
                                  default_user_experience_level: @default_user_experience_level.to_i
                                },
                              ])
        end
      end

      private

      # The sql statement for selecting based on relevance scores that
      # are user required.
      #
      # @todo Remember to not use "SELECT articles.*" and also
      #   consider pagination and the interaction with Kaminari.
      def sql_for_nil_user
        <<~THE_SQL_STATEMENT
          WITH top_articles AS (
            SELECT articles.id,
            (#{relevance_score_components_as_sql}) AS relevance_score
            FROM articles
            LEFT OUTER JOIN comments
              ON comments.commentable_id = articles.id
                AND comments.commentable_type = 'Article'
            WHERE published = true
            GROUP BY articles.id,
              articles.title,
              articles.published_at,
              articles.comments_count,
              articles.experience_level_rating,
              articles.spaminess_rating,
              articles.reactions_count
            ORDER BY relevance_score DESC,
              articles.published_at DESC
            #{offset_if_applicable} LIMIT :number_of_results)
          SELECT articles.*
          FROM articles
          INNER JOIN top_articles
            ON top_articles.id = articles.id
          WHERE relevance_score > 0
          ORDER BY articles.published_at DESC;
        THE_SQL_STATEMENT
      end

      # The sql statement for selecting based on relevance scores that
      # are user required.
      #
      # @todo Remember to not use "SELECT articles.*" and also
      #   consider pagination and the interaction with Kaminari.
      def sql_for_existing_user
        <<~THE_SQL_STATEMENT
          WITH top_articles AS (
            SELECT articles.id,
            (#{relevance_score_components_as_sql}) AS relevance_score
            FROM articles
            LEFT OUTER JOIN taggings
              ON taggings.taggable_id = articles.id
                AND taggable_type = 'Article'
            INNER JOIN tags
              ON taggings.tag_id = tags.id
            LEFT OUTER JOIN follows AS followed_tags
              ON tags.id = followed_tags.followable_id
                AND followed_tags.followable_type = 'ActsAsTaggableOn::Tag'
                AND followed_tags.follower_type = 'User'
                AND followed_tags.follower_id = :user_id
            LEFT OUTER JOIN follows AS followed_user
              ON articles.user_id = followed_user.followable_id
                AND followed_user.followable_type = 'User'
                AND followed_user.follower_id = :user_id
                AND followed_user.follower_type = 'User'
            LEFT OUTER JOIN follows AS followed_org
              ON articles.organization_id = followed_org.followable_id
                AND followed_org.followable_type = 'Organization'
                AND followed_org.follower_id = :user_id
                AND followed_org.follower_type = 'User'
            LEFT OUTER JOIN comments AS comments_by_followed
              ON comments_by_followed.commentable_id = articles.id
                AND comments_by_followed.commentable_type = 'Article'
                AND followed_user.followable_id = comments_by_followed.user_id
                AND followed_user.followable_type = 'User'
            LEFT OUTER JOIN user_blocks
              ON user_blocks.blocked_id = articles.user_id
                AND user_blocks.blocked_id IS NULL
                AND user_blocks.blocker_id = :user_id
            LEFT OUTER JOIN comments
              ON comments.commentable_id = articles.id
                AND comments.commentable_type = 'Article'
            WHERE published = true
            GROUP BY articles.id,
              articles.published_at,
              articles.comments_count,
              articles.experience_level_rating,
              articles.spaminess_rating,
              articles.reactions_count
            ORDER BY relevance_score DESC,
              articles.published_at DESC
            #{offset_if_applicable} LIMIT :number_of_results)
          SELECT articles.*
          FROM articles
          INNER JOIN top_articles
            ON top_articles.id = articles.id
          WHERE relevance_score > 0
          ORDER BY articles.published_at DESC;
        THE_SQL_STATEMENT
      end

      # We multiply the relevance score components together.
      def relevance_score_components_as_sql
        @relevance_score_components.join(" * ")
      end

      def offset_if_applicable
        return "" if @page == 1

        " OFFSET #{(@page - 1) * @number_of_results} "
      end

      # By default, we use all of the possible scoring methods.
      def default_scoring_configs
        SCORING_METHOD_CONFIGURATIONS
      end

      # This method converts the caller provided :scoring_configs into
      # an array of SQL clause fragments.
      #
      # @param scoring_configs [Hash] the caller provided configurations.
      #
      # @see SCORING_METHOD_CONFIGURATIONS
      # @note Be mindful to guard against SQL injection!
      def configure!(scoring_configs:)
        @relevance_score_components = []

        # We looping through the possible scoring method
        # configurations, we're only accepting those as valid
        # configurations.
        SCORING_METHOD_CONFIGURATIONS.each_pair do |valid_method_name, default_config|
          # Don't attempt to use this factor if we don't have user.
          next if default_config.fetch(:requires_user) && @user.nil?

          # Ensure that we're only using a scoring configuration that
          # the caller provided.
          next unless scoring_configs.key?(valid_method_name)

          scoring_config = scoring_configs.fetch(valid_method_name)

          # If the caller didn't provide a hash for this scoring configuration,
          # then we'll use the default configuration.
          scoring_config = default_config unless scoring_config.is_a?(Hash)

          @relevance_score_components << build_score_element_from(
            # Under NO CIRCUMSTANCES should you trust the caller to
            # provide a valid :clause.  Don't trust them to send a
            # valid clause.  That's the path of SQL injection.
            clause: default_config.fetch(:clause),
            # We can trust the :cases and :fallback a bit more, as we
            # later cast them to integers and floats.
            cases: scoring_config.fetch(:cases),
            fallback: scoring_config.fetch(:fallback),
          )
        end
      end

      # Responsible for transforming the :clause, :cases, and
      # :fallback into a SQL fragment that we can use to multiply with
      # the other SQL fragments.
      #
      # @param clause [String]
      # @param cases [Array<Array<#to_i, #to_f>>]
      # @param fallback [#to_f]
      def build_score_element_from(clause:, cases:, fallback:)
        text = "(CASE #{clause}"
        cases.each do |value, factor|
          text += "\nWHEN #{value.to_i} THEN #{factor.to_f}"
        end
        text += "\nELSE #{fallback.to_f} END)"
      end
    end
  end
end
