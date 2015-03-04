module Searchable
  extend ActiveSupport::Concern

  included do
    include Elasticsearch::Model

    # Customize the index name
    #
    index_name [Rails.application.engine_name, Rails.env].join('_')

    # Set up index configuration and mapping
    #
    settings index: { number_of_shards: 1, number_of_replicas: 0 } do
      mapping do
        indexes :title, type: 'multi_field' do
          indexes :title,     analyzer: 'snowball'
          indexes :tokenized, analyzer: 'simple'
        end

        indexes :content, type: 'multi_field' do
          indexes :content,   analyzer: 'snowball'
          indexes :tokenized, analyzer: 'simple'
        end

        indexes :published_on, type: 'date'

        indexes :authors do
          indexes :full_name, type: 'multi_field' do
            indexes :full_name
            indexes :raw, analyzer: 'keyword'
          end
        end

        indexes :categories, analyzer: 'keyword'

        indexes :comments, type: 'nested' do
          indexes :body, analyzer: 'snowball'
          indexes :stars
          indexes :pick
          indexes :user, analyzer: 'keyword'
          indexes :user_location, type: 'multi_field' do
            indexes :user_location
            indexes :raw, analyzer: 'keyword'
          end
        end
      end
    end

    # Set up callbacks for updating the index on model changes
    #
    after_commit lambda { Indexer.perform_async(:index,  self.class.to_s, self.id) }, on: :create
    after_commit lambda { Indexer.perform_async(:update, self.class.to_s, self.id) }, on: :update
    after_commit lambda { Indexer.perform_async(:delete, self.class.to_s, self.id) }, on: :destroy
    after_touch  lambda { Indexer.perform_async(:update, self.class.to_s, self.id) }

    # Customize the JSON serialization for Elasticsearch
    #
    def as_indexed_json(options={})
      hash = self.as_json(
        include: { authors:    { methods: [:full_name], only: [:full_name] },
                   comments:   { only: [:body, :stars, :pick, :user, :user_location] }
                 })
      hash['categories'] = self.categories.map(&:title)
      hash
    end

    # Search in title and content fields for `q`, include highlights in response
    #
    # @param q [String] The user query
    # @return [Elasticsearch::Model::Response::Response]
    #
    def self.search(q, options={})
      @search_definition = Elasticsearch::DSL::Search.search do
        query do
          unless q.blank?
            bool do
              should do
                multi_match do
                  query    q
                  fields   ['title^10', 'abstract^2', 'content']
                  operator 'and'
                end
              end
            end
          else
            match_all
          end
        end

        # TODO: Search also in *comments* -- `if query.present? && options[:comments]`

        aggregation :categories do
          # TODO: Has to be an `and` filter depending on multiple conditions
          #       Would be nice to do this ex post, as with the original `__set_filters` lambda
          #
          f = options[:author] ? { term: { 'authors.full_name.raw' => options[:author] } } : { match_all: {} }

          filter f do
            aggregation :categories do
              terms field: 'categories'
            end
          end
        end

        aggregation :authors do
          # DITTO
          f = options[:category] ? { term: { categories: options[:category] } } : { match_all: {} }

          filter f do
            aggregation :authors do
              terms field: 'authors.full_name.raw'
            end
          end
        end

        aggregation :published do
          # DITTO
          f = options[:category] ? { term: { categories: options[:category] } } : { match_all: {} }

          filter f do
            aggregation :published do
              date_histogram do
                field    'published_on'
                interval 'week'
              end
            end
          end
        end

        highlight fields: {
            title:    { number_of_fragments: 0 },
            abstract: { number_of_fragments: 0 },
            content:  { fragment_size: 50 }
          },
          pre_tags: ['<em class="label label-highlight">'],
          post_tags: ['</em>']

        case
          when options[:sort]
            sort options[:sort].to_sym => 'desc'
            track_scores true
          when q.blank?
            sort published_on: 'desc'
        end

        unless q.blank?
          suggest :suggest_title, text: q, term: { field: 'title.tokenized', suggest_mode: 'always' }
          suggest :suggest_body,  text: q, term: { field: 'content.tokenized', suggest_mode: 'always' }
        end

      end

      # require 'pry'; binding.pry;

      __elasticsearch__.search(@search_definition)
    end
  end
end
