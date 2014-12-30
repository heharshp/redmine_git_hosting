module RedmineGitHosting
  module GitoliteHandlers
    class RepositoryMover

      attr_reader :repository
      attr_reader :gitolite_config
      attr_reader :action


      def initialize(repository, gitolite_config, action)
        @repository      = repository
        @gitolite_config = gitolite_config
        @action          = action
      end


      def call
        if !repo_conf
          logger.error("#{action} : repository '#{old_repo_name}' does not exist in Gitolite, exit !")
          return
        else
          perform_repository_move
        end
      end


      private


        def perform_repository_move
          logger.info("#{action} : Moving '#{old_repo_name}' to '#{new_repo_name}' ...")

          # debug_output

          if move_physical_repo(old_relative_path, new_relative_path, new_relative_parent_path)
            # Update repository paths in database
            update_repository_fields

            # Update Gitolite configuration
            update_gitolite

            # Return old path to delete it
            old_relative_parent_path
          end
        end


        def update_repository_fields
          repository.update_column(:url, new_relative_path)
          repository.update_column(:root_url, new_relative_path)
        end


        def update_gitolite
          # Get old repository permissions
          old_perms = PermissionsBuilder.get_permissions(repo_conf)

          # Remove repository from Gitolite configuration
          gitolite_config.rm_repo(old_repo_name)

          # Recreate it
          RedmineGitHosting::GitoliteHandlers::RepositoryAdder.new(repository, gitolite_config, action, old_perms: old_perms).call
        end


        def repo_conf
          @repo_conf ||= gitolite_config.repos[old_repo_name]
        end


        def repo_id
          @repo_id ||= repository.redmine_name
        end


        def old_repo_name
          @old_repo_name ||= repository.old_repository_name
        end


        def new_repo_name
          @new_repo_name ||= repository.new_repository_name
        end


        def old_relative_path
         @old_relative_path ||= repository.url
       end


        def new_relative_path
         @new_relative_path ||= repository.gitolite_repository_path
       end


        def old_relative_parent_path
          @old_relative_parent_path ||= old_relative_path.gsub(repo_id + '.git', '')
        end


        def new_relative_parent_path
          @new_relative_parent_path ||= new_relative_path.gsub(repo_id + '.git', '')
        end


        def logger
          RedmineGitHosting.logger
        end


        def debug_output
          logger.info("move_repositories_tree : Old repository name (for Gitolite)           : #{old_repo_name}")
          logger.info("move_repositories_tree : New repository name (for Gitolite)           : #{new_repo_name}")
          logger.info("move_repositories_tree : Old relative path (for Redmine code browser) : #{old_relative_path}")
          logger.info("move_repositories_tree : New relative path (for Redmine code browser) : #{new_relative_path}")
          logger.info("move_repositories_tree : Old relative parent path (for Gitolite)      : #{old_relative_parent_path}")
          logger.info("move_repositories_tree : New relative parent path (for Gitolite)      : #{new_relative_parent_path}")
        end


        def move_physical_repo(old_path, new_path, new_parent_path)
          ## CASE 0
          if old_path == new_path
            logger.info("#{action} : old repository and new repository are identical '#{old_path}', nothing to do, exit !")
            return true
          end

          # Now we have multiple options, due to the way gitolite sets up repositories
          new_path_exists = directory_exists?(new_path)
          old_path_exists = directory_exists?(old_path)

          ## CASE 1
          if new_path_exists && old_path_exists
            return move_physical_repo_case_1(old_path, new_path)

          ## CASE 2
          elsif !new_path_exists && old_path_exists
            return move_physical_repo_case_2(old_path, new_path, new_parent_path)

          ## CASE 3
          elsif !new_path_exists && !old_path_exists
            logger.error("#{action} : both old repository '#{old_path}' and new repository '#{new_path}' does not exist, cannot move it, exit but let Gitolite create the new repo !")
            return true

          ## CASE 4
          elsif new_path_exists && !old_path_exists
            logger.error("#{action} : old repository '#{old_path}' does not exist, but the new one does, use it !")
            return true

          end
        end


        def move_physical_repo_case_1(old_path, new_path)
          if empty_repository?(new_path)
            logger.warn("#{action} : target repository '#{new_path}' already exists and is empty, remove it ...")
            delete_directory!(new_path, :target)
          else
            logger.warn("#{action} : target repository '#{new_path}' exists and is not empty, considered as already moved, try to remove the old_path if empty")
            if empty_repository?(old_path)
              delete_directory!(old_path, :source)
            else
              logger.error("#{action} : the source repository directory is not empty, cannot remove it, exit ! (This repo will be orphan)")
              false
            end
          end
        end


        def move_physical_repo_case_2(old_path, new_path, new_parent_path)
          logger.debug("#{action} : really moving Gitolite repository from '#{old_path}' to '#{new_path}'")

          create_parent_directory(new_parent_path) if !directory_exists?(new_parent_path)

          begin
            RedmineGitHosting::Commands.sudo_move(old_path, new_path)
          rescue RedmineGitHosting::Error::GitoliteCommandException => e
            logger.error("move_physical_repo(#{old_path}, #{new_path}) failed")
            return false
          else
            logger.info("#{action} : done !")
            return true
          end
        end


        def delete_directory!(dir, type)
          begin
            RedmineGitHosting::Commands.sudo_rmdir(dir, true)
            return true
          rescue RedmineGitHosting::Error::GitoliteCommandException => e
            logger.error("#{action} : removing existing #{type} repository failed, exit !")
            return false
          end
        end


        def empty_repository?(dir)
          RedmineGitHosting::Commands.sudo_repository_empty?(dir)
        end


        def directory_exists?(dir)
          RedmineGitHosting::Commands.sudo_dir_exists?(dir)
        end


        def create_parent_directory(new_parent_path)
          begin
            RedmineGitHosting::Commands.sudo_mkdir('-p', new_parent_path)
            return true
          rescue RedmineGitHosting::Error::GitoliteCommandException => e
            logger.error("#{action} : creation of parent path '#{new_parent_path}' failed, exit !")
            return false
          end
        end

    end
  end
end
