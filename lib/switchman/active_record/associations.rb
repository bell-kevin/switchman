# frozen_string_literal: true

module Switchman
  module ActiveRecord
    module Associations
      module Association
        def shard
          reflection.shard(owner)
        end

        def build_record(*args)
          shard.activate { super }
        end

        def load_target
          shard.activate { super }
        end

        def scope
          shard_value = @reflection.options[:multishard] ? @owner : shard
          @owner.shard.activate { super.shard(shard_value, :association) }
        end
      end

      module CollectionAssociation
        def find_target
          shards = reflection.options[:multishard] && owner.respond_to?(:associated_shards) ? owner.associated_shards : [shard]
          # activate both the owner and the target's shard category, so that Reflection#join_id_for,
          # when called for the owner, will be returned relative to shard the query will execute on
          Shard.with_each_shard(shards, [klass.connection_class_for_self, owner.class.connection_class_for_self].uniq) do
            super
          end
        end

        def _create_record(*)
          shard.activate { super }
        end
      end

      module BelongsToAssociation
        def replace_keys(record, force: false)
          if record&.class&.sharded_column?(reflection.association_primary_key(record.class))
            foreign_id = record[reflection.association_primary_key(record.class)]
            owner[reflection.foreign_key] = Shard.relative_id_for(foreign_id, record.shard, owner.shard)
          else
            super
          end
        end

        def shard
          if @owner.class.sharded_column?(@reflection.foreign_key) &&
             (foreign_id = @owner[@reflection.foreign_key])
            Shard.shard_for(foreign_id, @owner.shard)
          else
            super
          end
        end
      end

      module ForeignAssociation
        # significant change:
        #   * transpose the key to the correct shard
        def set_owner_attributes(record) # rubocop:disable Naming/AccessorMethodName
          return if options[:through]

          key = owner._read_attribute(reflection.join_foreign_key)
          key = Shard.relative_id_for(key, owner.shard, shard)
          record._write_attribute(reflection.join_primary_key, key)

          record._write_attribute(reflection.type, owner.class.polymorphic_name) if reflection.type
        end
      end

      module Extension
        def self.build(_model, _reflection); end

        def self.valid_options
          [:multishard]
        end
      end

      ::ActiveRecord::Associations::Builder::Association.extensions << Extension

      module Preloader
        module Association
          module LoaderQuery
            def load_records_in_batch(loaders)
              # While in theory loading multiple associations that end up being effectively the same would be nice
              # it's not very switchman compatible, so just don't bother trying to use that logic
              # raw_records = records_for(loaders)

              loaders.each do |loader|
                loader.load_records(nil)
                loader.run
              end
            end
          end

          # Copypasta from Activerecord but with added global_id_for goodness.
          def records_for(ids)
            scope.where(association_key_name => ids).load do |record|
              global_key = if model.connection_class_for_self == UnshardedRecord
                             convert_key(record[association_key_name])
                           else
                             Shard.global_id_for(record[association_key_name], record.shard)
                           end
              owner = owners_by_key[convert_key(global_key)].first
              association = owner.association(reflection.name)
              association.set_inverse_instance(record)
            end
          end

          # significant changes:
          #  * partition_by_shard the records_for call
          #  * re-globalize the fetched owner id before looking up in the map
          # TODO: the ignored param currently loads records; we should probably not waste effort double-loading them
          # Change introduced here: https://github.com/rails/rails/commit/c6c0b2e8af64509b699b782aadfecaa430700ece
          def load_records(raw_records = nil)
            # owners can be duplicated when a relation has a collection association join
            # #compare_by_identity makes such owners different hash keys
            @records_by_owner = {}.compare_by_identity

            if ::Rails.version < '7.0' && owner_keys.empty?
              raw_records ||= []
            else
              # determine the shard to search for each owner
              if reflection.macro == :belongs_to
                # for belongs_to, it's the shard of the foreign_key
                partition_proc = lambda do |owner|
                  if owner.class.sharded_column?(owner_key_name)
                    Shard.shard_for(owner[owner_key_name], owner.shard)
                  else
                    Shard.current
                  end
                end
              elsif !reflection.options[:multishard]
                # for non-multishard associations, it's *just* the owner's shard
                partition_proc = ->(owner) { owner.shard }
              end

              raw_records ||= Shard.partition_by_shard(owners, partition_proc) do |partitioned_owners|
                relative_owner_keys = partitioned_owners.map do |owner|
                  key = owner[owner_key_name]
                  if key && owner.class.sharded_column?(owner_key_name)
                    key = Shard.relative_id_for(key, owner.shard,
                                                Shard.current(klass.connection_class_for_self))
                  end
                  convert_key(key)
                end
                relative_owner_keys.compact!
                relative_owner_keys.uniq!
                records_for(relative_owner_keys)
              end
            end

            @preloaded_records = raw_records.select do |record|
              assignments = false

              owner_key = record[association_key_name]
              if owner_key && record.class.sharded_column?(association_key_name)
                owner_key = Shard.global_id_for(owner_key,
                                                record.shard)
              end

              owners_by_key[convert_key(owner_key)].each do |owner|
                entries = (@records_by_owner[owner] ||= [])

                if reflection.collection? || entries.empty?
                  entries << record
                  assignments = true
                end
              end

              assignments
            end
          end

          # significant change: globalize keys on sharded columns
          def owners_by_key
            @owners_by_key ||= owners.each_with_object({}) do |owner, result|
              key = owner[owner_key_name]
              key = Shard.global_id_for(key, owner.shard) if key && owner.class.sharded_column?(owner_key_name)
              key = convert_key(key)
              (result[key] ||= []) << owner if key
            end
          end

          # significant change: don't cache scope (since it could be for different shards)
          def scope
            build_scope
          end
        end
      end

      module CollectionProxy
        def initialize(*args)
          super
          self.shard_value = scope.shard_value
          self.shard_source_value = :association
        end

        def shard(*args)
          scope.shard(*args)
        end
      end

      module AutosaveAssociation
        def record_changed?(reflection, record, key)
          record.new_record? ||
            (record.has_attribute?(reflection.foreign_key) && record.send(reflection.foreign_key) != key) || # have to use send instead of [] because sharding
            record.attribute_changed?(reflection.foreign_key)
        end

        def save_belongs_to_association(reflection)
          # this seems counter-intuitive, but the autosave code will assign to attribute bypassing switchman,
          # after reading the id attribute _without_ bypassing switchman. So we need Shard.current for the
          # category of the associated record to match Shard.current for the category of self
          shard.activate(connection_class_for_self_for_reflection(reflection)) { super }
        end
      end
    end
  end
end
