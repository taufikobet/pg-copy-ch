# Excecution context for `Recipe`
# * this must be executed in the TABLE dir

class Data::Chef
  class Cooked < Exception
    def initialize(msg = nil)
      super(msg || self.class.name.to_s)
    end

    def group : String
      self.class.name.sub(/^.*::/, "")
    end
  end
  class OK     < Cooked; end
  class ERROR  < Cooked; end
  class SKIP   < Cooked; end
  class IGNORE < Cooked; end

  var recipe : Recipe
  var config : Config
  var dir    : String
  var label  : String
  var logger : Logger = Logger.new(STDOUT)

  delegate table, to: recipe
  delegate pg_db, pg_max_record_size, pg_ttl_count, to: config
  delegate psql, clickhouse_client, to: config

  def initialize(@recipe, @config, @label, @logger)
  end

  def cook : Cooked
    logger.debug "#{label} cook #{recipe}"
    raise execute(recipe)
  rescue cooked
    if !cooked.is_a?(Cooked)
      msg = cooked.to_s.strip
      cooked = ERROR.new("ERROR #{msg}")
    end

    case cooked
    when OK    ; logger.info  "#{label} #{cooked}".colorize(:green)
    when SKIP  ; logger.info  "#{label} #{cooked}".colorize(:cyan)
    when IGNORE; logger.warn  "#{label} #{cooked}".colorize(:yellow)
    when ERROR ; logger.error "#{label} #{cooked}".colorize(:red)
    end

    return cooked
  end
  
  def execute(recipe : Recipe::Skip) : OK
    raise SKIP.new(recipe.to_s)
  end

  def execute(recipe : Recipe::Ignore) : OK
    raise IGNORE.new(recipe.to_s)
  end

  def execute(recipe : Recipe::Control) : OK
    raise SKIP.new(recipe.to_s)
  end

  def execute(recipe : Recipe::Count) : OK
    try = Try(Time).try { Pretty::File.mtime(count_csv).to_local }
    if mtime = try.get?
      expired_at = mtime + pg_ttl_count.seconds
      if pg_ttl_count == Config::INFINITE || Pretty.now <= expired_at
        count = File.read(count_csv).to_i64
        return OK.new("Cached (already exists) [#{count}]")
      end
    end
    tbl = recipe.table

    query = "Copy (Select count(*) From #{tbl}) To STDOUT With CSV DELIMITER ','"
    Pretty::File.write(count_sql, query)
    logger.debug "  created data count #{count_sql}"

    psql("-f #{count_sql} #{pg_db} > #{count_csv}")
    logger.debug "  fetched data count #{count_csv}"

    count = File.read(count_csv).to_i64
    return OK.new("COUNT [#{count}]")
  end

  def execute(recipe : Recipe::GuardCount) : OK
    count = File.read(count_csv).to_i64
    max = pg_max_record_size
    if count <= max
      return OK.new("count [#{count}] is ok")
    else
      raise SKIP.new("SKIP count [#{count}] exceeded [#{max}]")
    end
  end

  def execute(recipe : Recipe::Replace) : OK
    guard_already_updated(ttl: config.ch_ttl_data)

    if pg_max_record_size >= 0
      execute(recipe.to(Recipe::Count))
      execute(recipe.to(Recipe::GuardCount))
    end

    create_meta_new
    create_data_csv(ttl: config.pg_ttl_data)
    import_data_new
    replace_by_new

    #    logger.info "#{hint} REPLACED (#{sec_from(t1)}s)".colorize(:green)
    return OK.new("REPLACE")
  end

  private def guard_already_updated(ttl)
    if ttl < 0
      logger.debug "  ch data (no ttl)"
      return OK.new("GuardDataTTL (no ttl)")
    elsif ch = recipe.ch?
      expired_at = ch.mtime + ttl.seconds
      if Pretty.now < expired_at
        raise SKIP.new("SKIP (updated at: #{ch.mtime})")
      else
        logger.debug "  (expired) last updated at: #{ch.mtime})"
        return OK.new("GuardDataTTL last updated at: #{ch.mtime}")
      end
    else
      return OK.new("GuardDataTTL (not updated yet)")
    end
  end

  private def create_meta_new
    data = String.build do |s|
      s.puts "DROP TABLE IF EXISTS #{table}_new;"
      s.puts recipe.pg.to_clickhouse.tap(&.table = "#{table}_new").to_sql
    end
    Pretty::File.write(meta_sql, data)
    logger.debug "  created #{meta_sql}"
    clickhouse_client("-mn < #{meta_sql}")
  end
  
  private def create_data_csv(ttl : Int64? = nil)
    if ttl
      mtime = Pretty::File.mtime(data_csv).to_local rescue nil
      if mtime
        expired_at = mtime + ttl.seconds
        if Pretty.now < expired_at
          logger.debug "  (cached) #{data_sql}"
          return true
        else
          logger.debug "  (expired) #{data_sql}"
        end
      end
    end

    Pretty::File.write(data_sql, recipe.pg.data_sql)
    logger.debug "  created #{data_sql}"

    # write tmp then move it to avoid file creation on error
    psql("-f #{data_sql} #{pg_db} > #{data_csv}.tmp")
    Pretty::File.mv("#{data_csv}.tmp", data_csv)
    
    logger.debug "  fetched #{data_csv}"
  end

  private def import_data_new
    # check whether empty or not to avoid error: "No data to insert"
    count = Shell::Seq.run!("wc -l < #{data_csv}").stdout.chomp.to_i64
    if count <= 1               # header line only
      raise SKIP.new("SKIP No data to insert")
    end
    
    num = config.ch_allow_errors_num
    clickhouse_client("-mn -q 'SET input_format_allow_errors_num = #{num}; INSERT INTO #{table}_new FORMAT CSVWithNames' < #{data_csv}")
    logger.debug "  inserted #{data_csv} into #{table}_new"
  end

  private def replace_by_new
    query = <<-EOF
      CREATE TABLE IF NOT EXISTS #{table} AS #{table}_new;
      DROP TABLE IF EXISTS #{table}_old;
      RENAME TABLE #{table} TO #{table}_old, #{table}_new TO #{table};
      DROP TABLE IF EXISTS #{table}_old;
      EOF

    clickhouse_client("-mn -q '#{query}'")
    logger.debug "  replaced by new table"
  end

  private var meta_sql  = "meta.sql"
  private var meta_csv  = "meta.csv"
  private var data_sql  = "data.sql"
  private var data_csv  = "data.csv"
  private var count_sql = "count.sql"
  private var count_csv = "count.csv"
end
