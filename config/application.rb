require_relative "boot"

require "rails/all"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module Semi
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.0

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    config.autoload_lib(ignore: %w[assets tasks])

    config.active_record.raise_int_wider_than_64bit = false

    # 只 dump public schema。
    #
    # 生产库在 Supabase 上，那里有一堆 Supabase 自己管的 schema（auth、storage、
    # realtime、vault…）和装在 extensions schema 里的扩展。默认的
    # :schema_search_path 会把它们全写进 db/schema.rb，而本地 Postgres 没有这些
    # —— 于是 db:test:prepare 加载失败，整个测试套件跑不起来。
    #
    # 这些 schema 本来也不归 Rails 管：Supabase 建项目时就有了，迁移也从不碰它们。
    config.active_record.dump_schemas = "public"

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # config.time_zone = "Central Time (US & Canada)"
    # config.eager_load_paths << Rails.root.join("extras")

    # Only loads a smaller set of middleware suitable for API only apps.
    # Middleware like session, flash, cookies can be added back manually.
    # Skip views, helpers and assets when generating a new resource.
    config.api_only = true

    # Ensure lib/ is eager loaded for custom libraries like tsid.rb
    config.eager_load_paths << Rails.root.join("lib")


    config.middleware.insert_before 0, Rack::Cors do
      allow do
        origins "*"
        resource "*", headers: :any, methods: [ :get, :post, :put, :patch, :delete, :options, :head ]
      end
    end
  end
end
