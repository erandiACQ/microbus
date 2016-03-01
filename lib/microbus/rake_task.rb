require 'bundler/gem_helper'
require 'rake'
require 'rake/tasklib'

require_relative 'docker'

module Microbus
  # Provides a custom rake task.
  class RakeTask < Rake::TaskLib
    Options = Struct.new(:build_path, :deployment_path, :docker_path,
                         :docker_cache, :docker_image, :filename, :files,
                         :gem_helper, :smoke_test_cmd) do
      class << self
        private :new

        def create(gem_helper, block = nil)
          o = new
          # Set defaults.
          o.build_path = "#{gem_helper.base}/build"
          o.deployment_path = "/opt/#{gem_helper.gemspec.name}"
          o.docker_path = "#{gem_helper.base}/docker"
          o.docker_image = "local/#{gem_helper.gemspec.name}-builder"
          o.filename = ENV['OUTPUT_FILE'] || 'build.tar.gz'
          o.files = gem_helper.gemspec.files
          o.gem_helper = gem_helper
          # Set user overrides.
          block.call(o) if block
          o.freeze
        end
      end
    end

    def initialize(name = :microbus, gem_name: nil, gem_base: nil, &block)
      @name = name.to_sym
      @gem_helper = Bundler::GemHelper.new(gem_base, gem_name)
      @block = block if block_given?
      declare_tasks
    end

    private

    def declare_tasks
      namespace @name do
        declare_build_task
        declare_clean_task
      end
      # Declare a default task.
      desc "Shortcut for #{@name}:build"
      task @name => ["#{@name}:build"]
    end

    def declare_build_task # rubocop:disable MethodLength, AbcSize
      desc "Build #{@gem_helper.gemspec.name} tarball"
      task :build do
        Rake::Task["#{@name}:clean"].invoke(false)

        # Copy only files declared in gemspec.
        sh("rsync -R #{opts.files.join(' ')} build")

        docker = Docker.new(
          path: opts.docker_path,
          tag: opts.docker_image,
          work_dir: opts.deployment_path,
          local_dir: opts.build_path,
          cache_dir: opts.docker_cache
        )

        docker.prepare

        Dir.chdir(opts.build_path) do
          Bundler.with_clean_env do
            # Package our dependencies, including git dependencies so that
            # docker doesn't need to fetch them all again (or need ssh keys.)
            # Package is much faster than bundle install --path and poses less
            # risk of cross-platform contamination.
            sh('bundle package --all --all-platforms --no-install')
            # Bundle package --all adds a "remembered setting" that causes
            # bundler to keep gems from all groups; delete config to allow
            # bundle install to prune.
            sh('rm .bundle/config')

            # @note don't use --deployment because bundler may package OS
            # specific gems, so we allow bundler to fetch alternatives while
            # running in docker if need be.
            # @todo When https://github.com/bundler/bundler/issues/4144
            # is released, --jobs can be increased.
            cmd =
              'bundle install' \
              ' --jobs 1' \
              ' --path vendor/bundle' \
              ' --standalone' \
              ' --binstubs binstubs' \
              ' --without development' \
              ' --clean' \
              ' --frozen'

            cmd << " && binstubs/#{opts.smoke_test_cmd}" if opts.smoke_test_cmd

            docker.run(cmd)
          end

          # Make it a tarball - note we exclude lots of redundant files, caches
          # and tests to reduce the size of the tarball.
          sh('tar' \
            ' --exclude="*.c" --exclude="*.h" --exclude="*.o"' \
            ' --exclude="*.gem" --exclude=".DS_Store"' \
            ' --exclude="vendor/bundle/ruby/*[0-9]/gems/*-*[0-9]/ext/"' \
            ' --exclude="vendor/bundle/ruby/*[0-9]/gems/*-*[0-9]/spec/"' \
            ' --exclude="vendor/bundle/ruby/*[0-9]/gems/*-*[0-9]/test/"' \
            ' --exclude="vendor/bundle/ruby/*[0-9]/extensions/"' \
            ' --exclude="vendor/cache/extensions/"' \
            " -czf ../#{opts.filename} *")

          puts "Created #{opts.filename}"

          docker.teardown
        end
      end
    end

    def declare_clean_task # rubocop:disable MethodLength, AbcSize
      desc 'Clean build artifacts'
      task :clean, :nuke, :tarball do |_t, args|
        args.with_defaults(nuke: true, tarball: opts.filename)

        # We don't delete the entire vendor so bundler runs faster (avoids
        # expanding gems and compiling native extensions again).
        FileUtils.mkdir('build') unless Dir.exist?('build')
        clean_files = Rake::FileList.new('build/**/*') do |fl|
          fl.exclude('build/vendor')
          fl.exclude('build/vendor/**/*')
        end
        clean_files << args[:tarball]
        clean_files << "#{@gem_helper.base}/build/" if args[:nuke]

        FileUtils.rm_rf(clean_files)
      end
    end

    # Lazily define opts so we don't slow down other rake tasks.
    # Don't call opts outside a task body.
    def opts
      @opts ||= Options.create(@gem_helper, @block)
    end
  end
end
