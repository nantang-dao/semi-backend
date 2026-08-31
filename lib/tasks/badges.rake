# frozen_string_literal: true

# 导入 semi-app/scripts/export-instant-badges.mjs 产出的 JSON。
#
#   bin/rails badges:import[/path/to/instant-export]
#   bin/rails badges:import[/path/to/instant-export,dry]   # 只报告，不写库
#   bin/rails badges:verify[/path/to/instant-export]       # 导完之后对账
#
# 幂等：按 instant_id 认行，重跑只更新不重复插入。
namespace :badges do
  # rake 文件在 :environment 之前就被加载，这里不能直接引用模型常量，
  # 否则 autoload 还没就绪，报 uninitialized constant。只存名字，用时再 constantize。
  FILES = {
    "profiles" => "BadgeProfile",
    "badge_classes" => "BadgeClass",
    "badges" => "Badge"
  }.freeze

  ID_FIELDS = {
    "profiles" => "profile_id",
    "badge_classes" => "class_id",
    "badges" => "badge_id"
  }.freeze

  # Instant 的 created_at 可能是 epoch 毫秒，也可能是 ISO 字符串。
  def self.parse_time(value)
    return nil if value.blank?
    return Time.at(value / 1000.0).utc if value.is_a?(Numeric)
    Time.parse(value.to_s).utc
  rescue ArgumentError
    nil
  end

  def self.load_rows(dir, name)
    path = File.join(dir, "#{name}.json")
    raise "找不到 #{path}" unless File.exist?(path)
    JSON.parse(File.read(path))
  end

  def self.attributes_for(model, row)
    common = {
      instant_id: row["id"],
      wallet_address: row["wallet_address"], # 原样，参与 namehash，不可 normalize
      chain_id: row["chain_id"]
    }

    case model.name
    when "BadgeProfile"
      common.merge(profile_id: row["profile_id"], tx_hash: row["tx_hash"])
    when "BadgeClass"
      common.merge(
        class_id: row["class_id"],
        profile_id: row["profile_id"],
        badge_contract_address: row["badge_contract_address"],
        metadata: row["metadata"] || {},
        tx_hash: row["tx_hash"]
      )
    when "Badge"
      common.merge(
        badge_id: row["badge_id"],
        class_id: row["class_id"],
        metadata: row["metadata"] || {},
        tx_hash: row["tx_hash"],
        status: row["status"],
        created_at: parse_time(row["created_at"]) || Time.current
      )
    end
  end

  desc "从 Instant 导出的 JSON 导入徽章数据（第二个参数传 dry 则只报告）"
  task :import, [ :dir, :mode ] => :environment do |_t, args|
    dir = args[:dir] or abort "用法: bin/rails badges:import[/path/to/instant-export]"
    dry = args[:mode].to_s == "dry"

    puts "源目录: #{dir}"
    puts "数据库: #{ActiveRecord::Base.connection_db_config.database}"
    puts dry ? "模式: DRY RUN（不写库）" : "模式: 实际写入"
    puts

    FILES.each do |name, model_name|
      model = model_name.constantize
      rows = load_rows(dir, name)
      created = updated = failed = 0
      errors = []

      ActiveRecord::Base.transaction do
        rows.each do |row|
          record = model.find_or_initialize_by(instant_id: row["id"])
          was_new = record.new_record?
          record.assign_attributes(attributes_for(model, row))

          if record.save
            was_new ? created += 1 : updated += 1
          else
            failed += 1
            errors << "#{row['id']}: #{record.errors.full_messages.join(', ')}"
          end
        end

        # dry run 也真的跑一遍写入，这样约束、校验全都实测过，最后再回滚。
        raise ActiveRecord::Rollback if dry
      end

      puts format("%-16s 源 %5d  新增 %5d  更新 %5d  失败 %5d", name, rows.size, created, updated, failed)
      errors.first(20).each { |e| puts "    ! #{e}" }
      puts "    …还有 #{errors.size - 20} 条" if errors.size > 20
    end

    puts
    puts dry ? "DRY RUN 已回滚，库未改动。" : "导入完成。跑 badges:verify 对账。"
  end

  desc "对账：比较导出的 JSON 与库里的实际数据"
  task :verify, [ :dir ] => :environment do |_t, args|
    dir = args[:dir] or abort "用法: bin/rails badges:verify[/path/to/instant-export]"
    ok = true

    FILES.each do |name, model_name|
      model = model_name.constantize
      rows = load_rows(dir, name)
      id_field = ID_FIELDS[name]

      source_ids = rows.map { |r| r[id_field] }.compact.to_set
      db_ids = model.pluck(id_field).to_set

      missing = source_ids - db_ids
      extra = db_ids - source_ids

      status = missing.empty? && extra.empty? ? "OK" : "不一致"
      puts format("%-16s 源 %5d  库 %5d  缺失 %4d  多余 %4d  %s",
                  name, source_ids.size, db_ids.size, missing.size, extra.size, status)

      missing.first(10).each { |i| puts "    - 库里没有: #{i}" }
      extra.first(10).each { |i| puts "    + 库里多出: #{i}" }
      ok = false unless missing.empty? && extra.empty?
    end

    # 地址大小写是这次迁移最容易出事的地方，单独查一遍。
    mangled = Badge.where("wallet_address = lower(wallet_address)")
                   .where("wallet_address ~ '^0x[0-9a-f]{40}$'").count
    puts
    puts "全小写地址的 badges: #{mangled} 行（若源数据是 checksummed，这个数应为 0）"

    abort "对账未通过" unless ok
    puts "对账通过。"
  end
end
