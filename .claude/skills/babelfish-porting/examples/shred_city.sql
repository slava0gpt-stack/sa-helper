-- Нативная замена XML-шреддинга: .nodes()/.query() не поддержаны Babelfish ни в одной версии.
-- ВОССТАНОВЛЕНО СО СТЕНДА через pg_get_functiondef. В репозитории этой функции не было:
-- она жила только внутри контейнера web-bbf и терялась при docker compose down -v (make clean).
-- LANGUAGE обязателен plpgsql (НЕ sql): sql-функция инлайнится в план,
-- и T-SQL-парсер Babelfish падает на 'syntax error at or near PATH'.
-- Из T-SQL вызывается как import.shred_city(...).
-- Накатывается на PostgreSQL-сторону: make native (psql в babelfish_db), НЕ через sqlcmd.
CREATE OR REPLACE FUNCTION web_import.shred_city(doc text)
 RETURNS TABLE(city_id integer, name text, region_id integer)
 LANGUAGE plpgsql
 STABLE
AS $function$
BEGIN
  RETURN QUERY
    SELECT c::int, n, r::int
      FROM xmltable('/city/r'
                    PASSING XMLPARSE(DOCUMENT doc)
                    COLUMNS c text PATH '@basis_city_id',
                            n text PATH '@name',
                            r text PATH '@basis_region_id');
END $function$
;
