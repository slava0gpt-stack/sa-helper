# Портирование процедуры под Babelfish 5.4.0 — рабочий рецепт

Кому: инженеру или агенту, которому дали процедуру MS SQL, не работающую на Babelfish,
и который должен выдать эквивалент. Файл самодостаточный — команды, шаблоны и методика
проверки внутри, читать что-то ещё не требуется.

**Правило номер один: порт считается сделанным только после запуска на ОБОИХ движках
и сравнения результата.** «Накатилось без ошибок» не означает «работает так же».
Из 41 портированной процедуры запуском проверены 2 (`import.city`, `import.enclosing`) —
остальные 39 пока только компилируются.

Все утверждения ниже с пометкой «замерено» проверены на стенде 2026-09-09,
команды для перепроверки приведены рядом.

---

## 0. Стенд и куда что класть

| Движок | Адрес | Пользователь | Пароль | База |
|---|---|---|---|---|
| MS SQL 2019 (эталон) | `tcp:localhost,24333` | `sa` | `Str0ng!Passw0rd` | `web` |
| Babelfish 5.4.0, T-SQL | `tcp:localhost,21433` | `babelfish_user` | `Bbf!Passw0rd` | `web` |
| Babelfish 5.4.0, нативный PG | `localhost:25433` или `docker exec web-bbf psql` | `babelfish_user` | — | `babelfish_db` |
| Нативный PostgreSQL 18 (второй трек) | `localhost:25434` | `web` | `Pg!Passw0rd` | `web` |

Поднять стенд: `make bench` (он же выставляет четыре `escape_hatch` — они не переживают
пересоздание контейнера).

Куда класть результат:

```
04_port/orig/<схема>.<имя>.sql      исходник с MS SQL, эталон, НЕ ПРАВИТЬ
04_port/ported/<схема>.<имя>.sql    портированная процедура (T-SQL)
04_port/ported/native/shred_<имя>.sql   нативная PL/pgSQL функция под XML
```

Схема T-SQL `<db>.<schema>` в нативном PG называется `<db>_<schema>`:
процедура `web.import.city` → функции для неё кладутся в схему `web_import`,
а из T-SQL вызываются как `import.shred_city(...)`.

**Ловушка сборки:** `make port` накатывает только `04_port/ported/*.sql`,
подкаталог `native/` он не трогает. Нативные функции наливаются отдельно (шаг 5 в §2).
Вторая ловушка: в `native/` в репозитории лежат 9 файлов, а в базе стенда живут 26 функций —
17 определений существуют только внутри контейнера. Выгрузить недостающее:

```bash
docker exec web-bbf psql -U babelfish_user -d babelfish_db -tAc \
  "select pg_get_functiondef('web_import.shred_enclosing'::regproc)"
```

---

## 1. Когда применять этот рецепт

### 1.1 По сообщению об ошибке

| Что видно | Когда | Блокер | Куда идти |
|---|---|---|---|
| `Msg 33557097 … 'MERGE' is not currently supported in Babelfish` | на `CREATE PROCEDURE`, не на выполнении | MERGE | §4.1 |
| `Msg 33557097 … 'XML NODES' is not currently supported in Babelfish` | на `CREATE PROCEDURE` | `.nodes()`, `.query()` | §4.4 |
| `Msg 52372 … No. 52372 in sys.messages` | при выполнении | `RAISERROR(<число>,16,1)` | §4.6 |
| текст сообщения из `FORMATMESSAGE` разошёлся с эталоном | при выполнении, только если среди аргументов есть NULL | `FORMATMESSAGE` | §4.5 |
| процедура попала в список сбоев `python3 03_schema/deploy.py bbf` или в `03_schema/90_quarantine.sql` | накат схемы | смотри текст рядом | §1.2 |
| работает, но результат отличается от эталона | сверка | чаще всего `UPDLOCK`/`NOLOCK`, порядок строк, коллация | §6 |

Признак «падает на CREATE, а не на EXEC» — важный: MERGE и `.nodes()` отвергает парсер,
поэтому такая процедура на Babelfish просто отсутствует, и любой её вызов даёт
«Could not find stored procedure». Ищи первопричину в логе наката, а не в вызове.

### 1.2 Что поддержано, а что нет

| Конструкция | Babelfish 5.4.0 | Комментарий |
|---|---|---|
| `MERGE` | **никогда**, ни в одной версии 1.0–6.2 | падает на `CREATE PROCEDURE` |
| `.nodes()`, `.query()` | **никогда** | падает на `CREATE PROCEDURE` |
| `.value()` | есть с 5.4.0 | замерено: `@x.value('(/a/r/@id)[1]','int')` → `7`, как на MS SQL |
| `.exist()` | есть с 4.4.0 | замерено: `1`, как на MS SQL. Не трогать |
| `FORMATMESSAGE` | парсится и считает | расходится на NULL-аргументе, см. §4.5 |
| `RAISERROR('текст',16,1)` | есть | батч **не обрывает** — ни здесь, ни на MS SQL (замерено) |
| `RAISERROR(<число>,16,1)` | `sys.messages` нет | текст сообщения другой, см. §4.6 |
| `THROW` | есть | батч обрывает на обоих движках (замерено) |
| `IIF`, `CHECKSUM`, `ISNULL`, `CONVERT` | есть | |
| табличные переменные `DECLARE @t TABLE`, `#temp`, `SELECT … INTO #t`, `DROP TABLE IF EXISTS #t` | есть | |
| `BEGIN TRY/CATCH`, `ERROR_NUMBER()`, `ERROR_MESSAGE()`, `ERROR_PROCEDURE()`, `ERROR_LINE()` | есть | |
| `SET NOCOUNT, ARITHABORT, XACT_ABORT ON` | есть | |
| `WITH (NOLOCK)`, `OPTION (MAXDOP/RECOMPILE)` | принимаются и **игнорируются** | молча |
| `WITH (UPDLOCK)` | принимается и **игнорируется** | паттерн «прочитал–проверил–записал» перестаёт быть защищённым |
| `OUTPUT` в `MERGE` | нет вместе с MERGE | рецепт §4.7, ни разу не применялся |
| `sys.geography` | нет типа, PostGIS в образе нет | хранение в WKT-строке |

Перепроверить поддержку конкретной конструкции — быстрее всего пробой:

```bash
cat > /tmp/probe.sql <<'EOF'
CREATE PROCEDURE dbo.zz_probe AS BEGIN
  <проверяемая конструкция>
END
EOF
SQLCMDPASSWORD='Bbf!Passw0rd' sqlcmd -S tcp:localhost,21433 -U babelfish_user -d web \
  -N disable -C -i /tmp/probe.sql
SQLCMDPASSWORD='Bbf!Passw0rd' sqlcmd -S tcp:localhost,21433 -U babelfish_user -d web \
  -N disable -C -Q "DROP PROCEDURE IF EXISTS dbo.zz_probe"
```

Пробу всегда гонять и на MS SQL (порт 24333, `sa`) — сравнивать надо с эталоном,
а не с ожиданием.

---

## 2. Порядок действий

### Шаг 1. Прочитать исходник целиком

```bash
cat 04_port/orig/import.city.sql
```

Если исходника нет в `orig/` — снять с эталона:

```bash
SQLCMDPASSWORD='Str0ng!Passw0rd' sqlcmd -S tcp:localhost,24333 -U sa -d web -N disable -C \
  -h -1 -W -y 0 -Q "SET NOCOUNT ON; SELECT definition FROM sys.sql_modules \
  WHERE object_id = OBJECT_ID('import.city')" > 04_port/orig/import.city.sql
```

Читать целиком, а не «по диагонали до первого MERGE». Нужны: сигнатура, все `RETURN`-коды,
все обращения к другим процедурам, блок `CATCH`.

### Шаг 2. Выписать блокеры

```bash
grep -nEi "MERGE[[:space:]]|\.nodes\(|\.query\(|\.value\(|\.exist\(|FORMATMESSAGE|RAISERROR\([[:space:]]*[0-9]|OUTPUT[[:space:]]+(INSERTED|DELETED)|NOLOCK|UPDLOCK|MAXDOP|RECOMPILE|geography" \
  04_port/orig/import.city.sql
```

Получится список из 3–6 пунктов. Он же станет шапкой файла (шаг 5).

### Шаг 3. Разобрать каждый MERGE на бумаге

Для каждого выписать:

1. **цель** — таблица и её PK/UK (нужно для §4.3);
2. **источник** — весь блок `USING (...)`: обращается ли он к таблицам, может ли дать
   несколько строк на один ключ `ON`;
3. **ON-условие** — переносится дословно, менять нельзя;
4. **список веток и их порядок**: `WHEN MATCHED [AND предикат]`,
   `WHEN NOT MATCHED [BY TARGET]`, `WHEN NOT MATCHED BY SOURCE [AND предикат]`;
5. **список и порядок колонок** в `INSERT`;
6. есть ли `OUTPUT`.

Без этой выписки разложение делать нельзя: в трёх ветках легко потерять доп. предикат.

### Шаг 4. Применить замены

Таблица замен — §3, готовые шаблоны — §4. Правила, которые не обсуждаются:

* бизнес-логику **не менять**: те же таблицы, те же условия, тот же порядок колонок;
* имена и типы параметров, значения по умолчанию, `RETURN`-коды — **не менять**;
* опечатки оригинала переносить **как есть** (в `ponominalu.job_ponominalu_repertoire_merge`
  в предикате `CHECKSUM` вместо `t.mixed_rank` стоит `s.mixed_rank` — перенесено дословно,
  с комментарием). Порт — это перевод, а не ревью;
* каждое отступление от оригинала — комментарием прямо в коде, в формате
  `-- было: <оригинал>` + причина.

### Шаг 5. Накатить

Сначала нативные функции (если появились), потом процедуру:

```bash
# нативная PL/pgSQL функция → в PostgreSQL, лежащий под Babelfish (НЕ в 25434!)
docker exec -i web-bbf psql -U babelfish_user -d babelfish_db -v ON_ERROR_STOP=1 \
  < 04_port/ported/native/shred_city.sql

# процедура → через TDS, в базу web
SQLCMDPASSWORD='Bbf!Passw0rd' sqlcmd -S tcp:localhost,21433 -U babelfish_user -d web \
  -N disable -C -l 30 -i 04_port/ported/import.city.sql
```

Вывод должен быть пустым. Любая строка `Msg …` — накат не прошёл, возвращайся к шагу 4.
Проверить, что объект действительно есть:

```bash
SQLCMDPASSWORD='Bbf!Passw0rd' sqlcmd -S tcp:localhost,21433 -U babelfish_user -d web \
  -N disable -C -h -1 -W -Q "SELECT 1 FROM sys.procedures WHERE object_id=OBJECT_ID('import.city')"
```

### Шаг 6. Проверить запуском — §5. Это не опция.

### Шаг 7. Шапка файла

Первые строки портированного файла — список блокеров и что с ними сделано.
Формат (сокращённый пример из `import.city.sql`):

```sql
-- ПОРТИРОВАНО ПОД BABELFISH 5.4.0. Исходник: [import].[city], 121 строка.
-- Блокеры и что с ними сделано:
--   1) @import_subdata.nodes('/city/r') + CROSS APPLY + i.q.value(...)
--        → нативная PL/pgSQL функция web_import.shred_city(doc text),
--          вызывается из T-SQL как import.shred_city(...).
--   2) MERGE dbo.city (MATCHED + NOT MATCHED) → UPDATE ... FROM ...; затем
--      INSERT ... WHERE NOT EXISTS. Порядок сохранён: сначала UPDATE, потом INSERT.
--   3) FORMATMESSAGE(...) → конкатенация с ISNULL(CONVERT(VARCHAR(20),...),'').
--   4) RAISERROR(52372,16,1) → RAISERROR с текстом, номер сохранён в тексте,
--      RETURN-код 52372 не изменён.
-- .exist() поддержан с Babelfish 4.4.0 — оставлен как был.
-- ПРОВЕРЕНО ЗАПУСКОМ: удачный путь / повтор / ошибка — см. §5, дата, кто.
```

Последняя строка обязательна и заполняется по факту. Если проверки не было —
так и писать: «ЗАПУСКОМ НЕ ПРОВЕРЕНО».

---

## 3. Таблица замен

| Конструкция MS SQL | Чем заменить | На что обратить внимание |
|---|---|---|
| `MERGE` c ветками | 2–3 отдельных DML: `UPDATE … FROM` (MATCHED) → `DELETE`/`UPDATE` (NOT MATCHED BY SOURCE) → `INSERT … WHERE NOT EXISTS` (NOT MATCHED) | Порядок именно такой. `INSERT` последним — иначе только что вставленные строки попадут под ветку BY SOURCE |
| блок `USING (…)` | материализовать в `#src` **до** разложения | Обязательно, если источник читает таблицы. MERGE работал по одному снимку; два обращения к источнику дадут два разных снимка (§6) |
| ветка `WHEN MATCHED AND <предикат>` | `ON`-условие → в `INNER JOIN`, предикат ветки → в `WHERE` | Дословно, включая `ISNULL(...)` и `CHECKSUM(...)` |
| ветка `WHEN NOT MATCHED [BY TARGET]` | `INSERT … SELECT … WHERE NOT EXISTS (то же ON-условие)` | Порядок и состав колонок `INSERT` сохранять |
| ветка `WHEN NOT MATCHED BY SOURCE THEN DELETE/UPDATE` | `DELETE`/`UPDATE` с `WHERE NOT EXISTS (то же ON-условие)` + доп. предикат ветки | Без доп. предиката чистится вся цель — это и есть поведение оригинала, не «оптимизировать» |
| **дубли в источнике** | явная проверка `IF EXISTS (… GROUP BY <ключ ON> HAVING COUNT(*)>1)` + `THROW`/`RAISERROR` | MERGE падал с 8672, разложенный `UPDATE … FROM` молча берёт одну строку. Новый тихий риск, созданный переписыванием (§4.3) |
| `@xml.nodes()` + `CROSS APPLY` + `.value()` | нативная функция в схеме `web_<схема>` на `xmltable()` | `LANGUAGE plpgsql`, **не** `sql`. Имена колонок в нижнем регистре. Типы — как у `.value()`, а не как у колонки-приёмника (§4.4) |
| `.value()`, `.exist()` | оставить как есть | Работают на 5.4.0 (замерено) |
| `FORMATMESSAGE(fmt, a, b, …)` | конкатенация с `ISNULL(CONVERT(VARCHAR(20), x),'')` | Работает, но при NULL-аргументе Babelfish портит все последующие аргументы (§4.5) |
| `RAISERROR(<число>, 16, 1)` | `RAISERROR('<число>: текст', 16, 1)` | `sys.messages` в Babelfish нет. Номер сохранять в тексте. `RETURN`-код не менять. `ERROR_NUMBER()` в CATCH станет 50000 |
| `WITH (NOLOCK)`, `OPTION (MAXDOP/RECOMPILE)` | оставить | Принимаются и игнорируются. Изменений в коде не требуют |
| `WITH (UPDLOCK)` | оставить + **предупредить владельца** | Игнорируется. Паттерн «прочитал–проверил–записал» открыт для гонки. Кодом это не чинится, нужно решение по логике |
| `OUTPUT` в `MERGE` | захват отдельным `SELECT` после `INSERT` (§4.7) | Рецепт ни разу не применялся, требует проверки на реальном случае |
| колонка `sys.geography` | `varchar` в WKT | Пространственные операции теряются |
| имя объекта > 63 символов | оставить | PostgreSQL молча укоротит до хеша. Затронуто 7 FK и 1 индекс. Если процедура ссылается на такое имя по строке — сломается |

---

## 4. Готовые шаблоны

Источники образцов — проверенные запуском файлы
`04_port/ported/import.city.sql` и `04_port/ported/import.enclosing.sql`.

### 4.1 MERGE → отдельные DML

Полный каркас. Порядок блоков менять нельзя.

```sql
BEGIN TRY

    -- 1. МАТЕРИАЛИЗАЦИЯ ИСТОЧНИКА (блок USING) — один снимок на все ветки.
    DROP TABLE IF EXISTS #src;

    SELECT <колонки источника, с CONVERT под длины из .value()/цели>
      INTO #src
      FROM <всё, что было внутри USING(...)>;

    -- 2. СТРАХОВКА ОТ ДУБЛЕЙ — §4.3 (если ключ цели не страхует).

    -- 3. Ветка WHEN MATCHED AND <предикат> THEN UPDATE
    UPDATE t
       SET t.<col1> = s.<col1>
         , t.<col2> = s.<col2>
      FROM <цель> AS t
     INNER JOIN #src AS s ON <ON-условие MERGE дословно>
     WHERE <предикат ветки MATCHED дословно>;   -- предиката не было → WHERE нет

    -- 4. Ветка WHEN NOT MATCHED BY SOURCE THEN DELETE
    DELETE t
      FROM <цель> AS t
     WHERE NOT EXISTS (
           SELECT 1 FROM #src AS s
            WHERE <ON-условие дословно> )
       AND <доп. предикат ветки, если был>;

    -- 4'. …или тот же случай, но THEN UPDATE (пометка «удалено логически»)
    UPDATE t
       SET t.is_revoked = 1
         , t.is_revoked_last_update_time = GETDATE()
      FROM <цель> AS t
     WHERE NOT EXISTS (
           SELECT 1 FROM #src AS s
            WHERE <ON-условие дословно> )
       AND <доп. предикат ветки>;

    -- 5. Ветка WHEN NOT MATCHED [BY TARGET] THEN INSERT — ПОСЛЕДНЕЙ
    INSERT INTO <цель> (
           <колонки строго в порядке оригинала>)
    SELECT s.<...>
         , s.<...>
      FROM #src AS s
     WHERE NOT EXISTS (
           SELECT 1 FROM <цель> AS t
            WHERE <ON-условие дословно> );

    DROP TABLE IF EXISTS #src;
END TRY
```

Почему такой порядок: `UPDATE` первым — иначе он зацепит строки, вставленные `INSERT`-ом
(у MERGE такого не было, ветки работают по одному снимку цели). `INSERT` последним —
иначе его строки попадут под ветку `NOT MATCHED BY SOURCE` и будут тут же удалены/погашены.
Ветки `MATCHED` и `NOT MATCHED BY SOURCE` работают по непересекающимся множествам,
их взаимный порядок на результат не влияет.

Рабочий пример (`import.city`, ветки MATCHED + NOT MATCHED):

```sql
UPDATE t
   SET t.[name]    = s.[name]
     , t.region_id = s.region_id
  FROM dbo.city AS t
 INNER JOIN @cities_to_import AS s ON t.city_id = s.city_id
 WHERE t.[name] <> s.[name]
    OR t.region_id <> s.region_id;

INSERT INTO dbo.city (city_id, region_id, [name])
SELECT s.city_id, s.region_id, s.[name]
  FROM @cities_to_import AS s
 WHERE NOT EXISTS (SELECT 1 FROM dbo.city AS t WHERE t.city_id = s.city_id);
```

Рабочий пример ветки только `NOT MATCHED` (`import.enclosing`):

```sql
INSERT INTO dbo.enclosing (hall_id, section_id)
SELECT s.hall_id, s.section_id
  FROM ( <источник из USING целиком> ) AS s
 WHERE NOT EXISTS (
       SELECT 1 FROM dbo.enclosing AS t
        WHERE t.hall_id = s.hall_id AND t.section_id = s.section_id );
```

### 4.2 Материализация источника

```sql
DROP TABLE IF EXISTS #src;

SELECT x.[basis_user_id]                       AS [basis_user_id]
     , CONVERT(NVARCHAR(250), x.[description]) AS [description]
  INTO #src
  FROM import.shred_basis_user( CONVERT(VARCHAR(MAX), @import_subdata) ) AS x;
```

Правила:

* `#src` строится **внутри** `BEGIN TRY`, если в оригинале источник был частью MERGE:
  ошибки разбора XML и приведения типов должны попадать в тот же `CATCH`, что и раньше;
* `CONVERT(NVARCHAR(n), …)` здесь повторяет усечение, которое в MS SQL делал
  `.value('@name','nvarchar(250)')`. Без него длинная строка дойдёт до `INSERT`
  и даст ошибку там, где оригинал молча обрезал;
* единственное законное исключение — источник вида `USING (SELECT @переменная AS x) AS s`:
  таблиц не читает, разъехаться не может (так сделано в `import.info_upsert`,
  и там это объяснено комментарием на 10 строк).

### 4.3 Страховка от дублей в источнике (бывшая ошибка 8672)

Когда нужна: **есть ветка `WHEN MATCHED`** и источник теоретически может дать
две строки на один ключ `ON`. PK/UK цели здесь не помогает: он отбивает только
повторный `INSERT` (ошибка 2627), а двойной `UPDATE` одной и той же строки цели
уникальным ключом не ловится вообще.

Когда не нужна (и тогда это надо написать в шапке): источник — одна строка из
переменной; веток `MATCHED` нет вовсе; источник — `SELECT` без соединений,
дающий по построению уникальный ключ.

**Вариант А — процедура без `TRY/CATCH`: только `THROW`.**

```sql
IF EXISTS (
       SELECT 1
         FROM #performances
        GROUP BY performance_id, sale_channel_id
       HAVING COUNT(*) > 1 )
    BEGIN
        -- Как MERGE в MS SQL: ошибка поднимается, цель не тронута,
        -- выполнение процедуры и батча прекращается.
        THROW 58672, '8672: duplicate rows in source #performances for ponominalu.performance (key: performance_id, sale_channel_id)', 1;
    END;
ELSE
    BEGIN
        <UPDATE / DELETE / INSERT из §4.1>
    END;
```

Номер `58672` = 50000 + 8672 (`THROW` требует код ≥ 50000), исходный номер сохранён
в начале текста. Оформление `IF … ELSE` гарантирует, что при срабатывании цель не тронута.

Почему именно `THROW`, замерено на обоих движках 2026-09-09:

```
RAISERROR('probe',16,1) между двумя SELECT → печатаются оба SELECT (батч НЕ оборван).
THROW 58672,'probe',1  между двумя SELECT → второй SELECT не выполняется (батч оборван).
Поведение MS SQL и Babelfish 5.4.0 в обоих случаях одинаковое.
```

Ошибка 8672 в MS SQL батч обрывает. Значит буквальная замена на `RAISERROR`
дала бы расхождение с оригиналом: остаток процедуры продолжил бы работу.

**Вариант Б — проверка внутри `BEGIN TRY`: допустим `RAISERROR`.**

```sql
IF EXISTS (
       SELECT 1
         FROM #basis_user_src AS s
        INNER JOIN dbo.basis_user AS t ON t.basis_user_id = s.basis_user_id
        WHERE ISNULL(t.[description],'') <> ISNULL(s.[description],'')
        GROUP BY s.basis_user_id
       HAVING COUNT(*) > 1 )
    BEGIN
        RAISERROR('8672: duplicate rows in source for dbo.basis_user', 16, 1);
    END;
```

`RAISERROR` внутри `TRY` перехватывается `CATCH`, а тот делает `ROLLBACK` и `RETURN` —
поток управления совпадает с оригиналом. Оговорка, которую надо записать в шапке:
`ERROR_NUMBER()` вернёт **50000**, а не 8672, поэтому `RETURN @ERROR_NUMBER` в этом
аварийном сценарии отдаст другое число. Сам номер 8672 сохранён в тексте.

Проверка сужается ровно до случая, в котором MS SQL и поднимал 8672: дубль ключа,
который (а) матчится со строкой цели и (б) проходит предикат ветки `MATCHED`.
Дубли без пары в цели проверку не задевают и идут в `INSERT`, где их, как и раньше,
отбивает PK.

### 4.4 XML: `.nodes()` → нативная функция на `xmltable()`

Шаблон функции (образец — `04_port/ported/native/shred_region.sql`):

```sql
-- Нативная замена XML-шреддинга для [import].[region].
-- В T-SQL было:
--   FROM @import_subdata.nodes('/region/r') AS I(Q)
--        CROSS APPLY (SELECT i.q.value('@basis_region_id','int') AS region_id
--                          , i.q.value('@name','nvarchar(250)')  AS [name]) AS x
-- LANGUAGE обязателен plpgsql (НЕ sql): sql-функция инлайнится в план,
-- и T-SQL-парсер Babelfish падает на 'syntax error at or near PATH'.
CREATE OR REPLACE FUNCTION web_import.shred_region(doc text)
RETURNS TABLE(region_id integer
            , name      text)
LANGUAGE plpgsql STABLE AS $function$
BEGIN
  -- Пустой/NULL документ -> пустая выборка, как .nodes() над пустым XML.
  IF doc IS NULL OR btrim(doc) = '' THEN
    RETURN;
  END IF;

  RETURN QUERY
    SELECT t.a_region_id::int
         , t.a_name
      FROM xmltable('/region/r'
                    PASSING XMLPARSE(DOCUMENT doc)
                    COLUMNS a_region_id text PATH '@basis_region_id',
                            a_name      text PATH '@name') AS t;
END $function$;
```

Вызов из T-SQL (в процедуре пишется короткое имя схемы, без префикса `web_`):

```sql
SELECT x.[city_id]
     , CONVERT(NVARCHAR(250), x.[name])
     , x.region_id
  FROM import.shred_city( CONVERT(VARCHAR(MAX), @import_subdata) ) AS x;
```

Замерено 2026-09-09 — вызов работает, кириллица проходит:

```
DECLARE @x XML = '<city><r basis_city_id="1" name="Москва" basis_region_id="77"/></city>';
SELECT * FROM import.shred_city( CONVERT(VARCHAR(MAX), @x) );
→ 1 | Москва | 77
```

Обязательные правила:

1. `LANGUAGE plpgsql`. С `LANGUAGE sql` функция инлайнится в план, и T-SQL-парсер
   Babelfish падает на `syntax error at or near "PATH"`. Это не стилистика, а блокер.
2. Параметр — `text`, на входе `CONVERT(VARCHAR(MAX), @xml)`. Тип `xml` в сигнатуру
   не тащить: из T-SQL его передавать нечем.
3. Имена выходных колонок — **в нижнем регистре**: T-SQL-парсер Babelfish
   приводит идентификаторы к lower, `RegionId` он не найдёт.
4. Типы приводить **как в `.value()`, а не как у колонки-приёмника**.
   Если `.value('@basis_visit_type_id','int')` разбирал в `int`, а колонка цели `TINYINT`,
   то и функция обязана вернуть `integer`: в MS SQL значение 300 давало ошибку
   переполнения на `INSERT`, а не на разборе XML. Приведение к `tinyint` внутри функции
   сместило бы точку и текст ошибки.
5. Строки возвращать как `text`, усечение до `nvarchar(n)` делать `CONVERT`-ом
   в вызывающей процедуре — там же, где его делал `.value()`.
6. Пустой или NULL документ → пустая выборка (ранний `RETURN`), как `.nodes()`
   над пустым XML.
7. Схема — `web_<схема T-SQL>`, имя — `shred_<объект>`. Файл класть в
   `04_port/ported/native/`, иначе определение останется только в контейнере.

### 4.5 `FORMATMESSAGE` → конкатенация

Замерено 2026-09-09 (это уточняет более раннюю запись «FORMATMESSAGE не поддержана»):
функция на 5.4.0 **парсится и считает**, и на аргументах без NULL даёт тот же текст,
что MS SQL. Расхождение появляется, когда среди аргументов есть NULL:

```
FORMATMESSAGE('A=%s|B=%s|C=%s', NULL, 'b', 'c')
   MS SQL     → A=(null)|B=b|C=c
   Babelfish  → A=(null)|B=(null)|C=(null)      ← испорчены все последующие аргументы
```

Для `CATCH`-блоков это не теория: `ERROR_PROCEDURE()` равен NULL, когда ошибка
поднята вне процедуры, — и текст сообщения молча разъезжается с эталоном.
Поэтому замена остаётся правильной. Шаблон (`import.city`):

```sql
DECLARE @MSG VARCHAR(2000);
SELECT @MSG = 'ERROR_NUMBER = '     + ISNULL(CONVERT(VARCHAR(20),@ERROR_NUMBER),'')
            + ', ERROR_MESSAGE = '  + ISNULL(@ERROR_MESSAGE,'')
            + ', ERROR_PROCEDURE = '+ ISNULL(@ERROR_PROCEDURE,'')
            + ', ERROR_LINE = '     + ISNULL(CONVERT(VARCHAR(20),@ERROR_LINE),'');
```

Отличие от оригинала честно фиксируется в шапке: `FORMATMESSAGE` на NULL-аргументе
даёт `(null)`, а конкатенация с `ISNULL` — пустую строку. Текст сообщения в аварийном
пути отличается от MS SQL. Если это неприемлемо — писать `ISNULL(x,'(null)')`.

### 4.6 `RAISERROR(<число>)` → текст с номером

```sql
-- было: RAISERROR(52372, 16, 1) — номер сообщения из sys.messages,
-- которой в Babelfish нет. Номер перенесён в текст, RETURN не тронут.
RAISERROR('52372: NO DATA in /city/r', 16, 1);
RETURN 52372;
```

Замерено 2026-09-09, `RAISERROR(52372,16,1)` без `sp_addmessage`:

```
Babelfish → Msg 52372, Level 16 … No. 52372 in sys.messages
MS SQL    → Msg 18054, Level 16 … Error 52372 … no message with that error number was found
```

То есть номер в шапке сообщения Babelfish сохраняет, а текст даёт свой.
После замены на текстовый вариант номер в шапке станет 50000 на обоих движках,
поэтому исходный номер и уносится в начало строки. `RETURN`-код **не менять никогда**:
на нём завязаны вызывающие джобы.

### 4.7 Канонический `CATCH`

```sql
BEGIN CATCH
    IF @@TRANCOUNT > 0
        ROLLBACK TRANSACTION;
    DECLARE @ERROR_PROCEDURE VARCHAR(256)=ERROR_PROCEDURE();
    DECLARE @ERROR_NUMBER INT=ERROR_NUMBER();
    DECLARE @ERROR_MESSAGE VARCHAR(2000)=ERROR_MESSAGE();
    DECLARE @ERROR_LINE INT=ERROR_LINE();
    DECLARE @MSG VARCHAR(2000);
    <конкатенация из §4.5>
    EXEC [import].[info_upsert] @task_name=@task_name, @info=@MSG, @task_state='ERROR';
    RAISERROR(@MSG, 16, 1);
    RETURN @ERROR_NUMBER;
END CATCH;
```

### 4.8 `OUTPUT` в `MERGE` — рецепт, ни разу не применённый

```sql
-- 1. ключи вставленных строк собираются отдельным SELECT после INSERT
INSERT INTO <цель> (<колонки>)
SELECT <...> FROM #src AS s
 WHERE NOT EXISTS (SELECT 1 FROM <цель> AS t WHERE <ON>);

-- 2. то, что MERGE отдавал через OUTPUT INSERTED.*, добирается запросом
INSERT INTO #out (<колонки>)
SELECT t.<...>
  FROM <цель> AS t
 INNER JOIN #src AS s ON <ON-условие>;
```

Помечать в шапке как **непроверенный** рецепт и проверять запуском по §5 обязательно:
для `OUTPUT` с ветками `UPDATE`/`DELETE` понадобится собирать состояние до, а не после.

---

## 5. Как проверять результат

Методика: снять состояние цели **до**, выполнить одно и то же на обоих движках,
снять состояние **после**, сравнить. Три сценария: удачный путь, повтор, ошибка.

### 5.0 Предусловия — без них сравнение врёт

1. **Данные в обоих движках одинаковые.** Загружены `make data`; на стенде это
   73 403 строки в 17 таблицах.
2. **Проверки FK в одинаковом состоянии.** `ALTER TABLE … NOCHECK CONSTRAINT ALL`
   Babelfish принимает без ошибки и **не выполняет** — молчаливая заглушка,
   ключи остаются включёнными. Отключаются они только так:

   ```bash
   docker exec web-bbf psql -U babelfish_user -d babelfish_db \
     -c "ALTER DATABASE babelfish_db SET session_replication_role = 'replica';"
   ```

   **Перед любым сравнением обязательно вернуть:**

   ```bash
   docker exec web-bbf psql -U babelfish_user -d babelfish_db \
     -c "ALTER DATABASE babelfish_db RESET session_replication_role;"
   ```

   Настройка применяется к новым сессиям, проверить текущее значение:
   `docker exec web-bbf psql -U babelfish_user -d babelfish_db -c "SHOW session_replication_role;"`
   Уже наступали: забыли вернуть → движки оказались в неравных условиях → ложное
   расхождение и потерянное время на разбор.
3. **Из сравнения исключены журнальные таблицы.** `import.info` заполняется
   `GETDATE()`, её строки не совпадут никогда. Сравнивать целевые таблицы,
   `RETURN`-код и класс ошибки — но не метки времени.

### 5.1 Скелет проверки

```bash
#!/usr/bin/env bash
set -u
PROC='import.city'
SNAP="SET NOCOUNT ON; SELECT city_id, ISNULL(name,'<NULL>'), region_id FROM dbo.city ORDER BY city_id;"
W=/tmp/port_check; mkdir -p $W

ms () { SQLCMDPASSWORD='Str0ng!Passw0rd' sqlcmd -S tcp:localhost,24333 -U sa -d web \
        -N disable -C -h -1 -W -s "|" -y 0 -Q "$1"; }
bf () { SQLCMDPASSWORD='Bbf!Passw0rd'  sqlcmd -S tcp:localhost,21433 -U babelfish_user -d web \
        -N disable -C -h -1 -W -s "|" -y 0 -Q "$1"; }

# --- ДО
ms "$SNAP" > $W/ms_before.txt ; bf "$SNAP" > $W/bf_before.txt
diff $W/ms_before.txt $W/bf_before.txt && echo "OK: стартовое состояние одинаковое" \
  || { echo "СТОП: движки разошлись ещё до запуска"; exit 1; }

# --- ЗАПУСК с одним и тем же входом, с перехватом RETURN-кода
CALL="SET NOCOUNT ON;
DECLARE @x XML = '<city><r basis_city_id=\"900001\" name=\"Тестовое\" basis_region_id=\"77\"/></city>';
DECLARE @rc INT;
EXEC @rc = $PROC @import_subdata = @x;
SELECT 'RC=' + CONVERT(VARCHAR(10), @rc);"
ms "$CALL" > $W/ms_run.txt 2>&1 ; bf "$CALL" > $W/bf_run.txt 2>&1

# --- ПОСЛЕ
ms "$SNAP" > $W/ms_after.txt ; bf "$SNAP" > $W/bf_after.txt

echo "--- RETURN-код и сообщения:"; diff $W/ms_run.txt   $W/bf_run.txt
echo "--- состояние цели после:";    diff $W/ms_after.txt $W/bf_after.txt
echo "--- что изменил MS SQL:";      diff $W/ms_before.txt $W/ms_after.txt
echo "--- что изменил Babelfish:";   diff $W/bf_before.txt $W/bf_after.txt
```

Флаги `sqlcmd` подобраны так, чтобы вывод был диффабельным: `-h -1` убирает шапку,
`-W` режет хвостовые пробелы, `-s "|"` фиксирует разделитель, `-y 0` не обрезает
длинные значения. Замерено: на неизменных данных `diff` даёт пустой вывод —
1242 строки `dbo.city` совпали на обоих движках байт в байт.

Осторожно с `-W`: он обрезает пробелы, поэтому колонки, где пробелы значимы
(в `dbo.obj` есть 28 имён из одних пробелов), в снимке надо оборачивать:
`'['+name+']'`.

### 5.2 Сценарий 1 — удачный путь

Вход: валидный XML, порождающий работу во всех ветках сразу — строка, которая
в цели уже есть с другими значениями (ветка UPDATE), новая строка (ветка INSERT),
и, если у процедуры есть ветка `BY SOURCE`, строка цели, которой во входе нет.

Критерий приёмки:
* `diff ms_after bf_after` пустой;
* `RC` совпал;
* оба движка реально что-то изменили (`ms_before` ≠ `ms_after`) — иначе проверка
  прошла вхолостую и ничего не доказывает.

### 5.3 Сценарий 2 — повтор (идемпотентность)

Запустить ту же процедуру с тем же входом второй раз, снять снимок снова.

Критерий приёмки:
* `diff ms_after2 bf_after2` пустой;
* `diff ms_after ms_after2` — то же самое, что `diff bf_after bf_after2`.
  Обычно оба пустые: повторный прогон ничего не меняет. Если оригинал на повторе
  что-то менял (например, `last_update_time`), порт обязан менять ровно столько же.

Этот сценарий ловит главную ошибку разложения — потерянный `WHERE NOT EXISTS`
или неверный порядок `UPDATE`/`INSERT`: они проявляются именно на втором прогоне
дублями или лишними обновлениями.

### 5.4 Сценарий 3 — ошибка

Два обязательных входа:

1. **пустой/невалидный XML** — должен сработать ранний выход:
   `RC = 52372` и на MS SQL, и на Babelfish, цель не изменилась;
2. **нарушение ограничения** — например, ссылка на несуществующего родителя,
   дающая ошибку FK 547. На `import.enclosing` это замерено: код 547 совпал
   на обоих движках.

Критерий приёмки:
* совпал `RC`;
* совпал номер ошибки в сообщении (`Msg NNN`), либо расхождение **объяснено и записано**
  (типовые объяснимые: 8672 → 50000 из-за `RAISERROR`, 52372 → 50000 после замены
  числового кода на текст);
* `diff before after` пустой на **обоих** движках — упавшая процедура не должна
  оставлять частичных изменений.

Если после ошибки цель на одном движке изменилась, а на другом нет —
это провал: разложение потеряло атомарность MERGE.

### 5.5 Чего эта методика не покрывает

Записывать честно, не выдавать за проверенное:
* **конкурентность.** Атомарность разложенного MERGE под параллельной нагрузкой
  не проверялась ни разу. Два одновременных вызова никто не запускал;
* **производительность.** Планы Babelfish против MS SQL не сравнивались вообще;
* **вызовы мимо процедур.** 17 запросов с MERGE и XML идут в базу напрямую
  из приложения и джобов. Портирование процедур их не покрывает.

---

## 6. Чего НЕ делать

1. **Не писать `LANGUAGE sql` в нативной функции.** SQL-функция инлайнится в план,
   и T-SQL-парсер падает с `syntax error at or near "PATH"`. Только `plpgsql`.
2. **Не заменять `THROW` на `RAISERROR` вне `TRY/CATCH`.** `RAISERROR` severity 16
   батч не обрывает (замерено на обоих движках), а ошибка 8672 в MS SQL обрывала.
   Буквальная замена даёт расхождение: остаток процедуры доработает до конца.
3. **Не забывать материализовать источник.** Если `USING` читает таблицы, а `UPDATE`
   и `INSERT` обращаются к нему по отдельности — они видят разные снимки. MERGE работал
   по одному. Это тихая потеря/дублирование строк, на глаз не видная.
4. **Не выкидывать проверку дублей**, полагаясь на PK цели. PK отбивает только
   повторный `INSERT` (2627). Самый опасный случай — две строки источника обновляют
   одну существующую строку цели — уникальным ключом не ловится, `UPDATE … FROM`
   молча возьмёт одну строку недетерминированно.
5. **Не сравнивать движки при разных настройках FK.** `NOCHECK CONSTRAINT ALL` на
   Babelfish — молчаливая заглушка. Отключать через `session_replication_role='replica'`
   и **обязательно** делать `RESET` перед сравнением.
6. **Не приводить типы в шред-функции к типу колонки-приёмника.** `.value('…','int')`
   разбирал в `int`, ошибка переполнения возникала на `INSERT`. Приведение к `tinyint`
   внутри функции сместит точку и текст ошибки.
7. **Не менять `RETURN`-коды, имена и типы параметров, порядок колонок `INSERT`.**
   На них завязаны вызывающие джобы и приложение.
8. **Не «чинить» логику оригинала по дороге.** Опечатки, странные предикаты, лишние
   присваивания в `SET` — переносить дословно, с комментарием. Порт и рефакторинг —
   разные задачи, и смешивать их значит потерять возможность сравнить с эталоном.
9. **Не менять порядок разложения.** `UPDATE` → `NOT MATCHED BY SOURCE` → `INSERT`.
   Любой другой порядок даёт другой результат на повторном прогоне.
10. **Не наливать нативную функцию в PostgreSQL на 25434.** Это второй трек сравнения,
    отдельная база. Babelfish читает свой PG — 25433 / `docker exec web-bbf psql`,
    база `babelfish_db`.
11. **Не полагаться на `make port` в части `native/`.** Он накатывает только
    `ported/*.sql`. Функции — руками, до процедуры.
12. **Не выставлять `escape_hatch` через `ALTER SYSTEM`** — отвечает
    «cannot be changed». Только `EXEC sp_babelfish_configure '<имя>','ignore','server'`,
    а для боевой установки — в `postgresql.conf`.
13. **Не считать `UPDLOCK` работающим.** Хинт игнорируется, «прочитал–проверил–записал»
    больше не защищён. Кодом порта это не лечится — эскалировать владельцу логики.
14. **Не писать в шапке «проверено», если запуска не было.** Из 41 процедуры
    запуском проверены 2; ложная пометка стоит дороже отсутствующей.

---

## 7. Чек-лист приёмки

```
[ ] исходник лежит в 04_port/orig/, не изменён
[ ] все блокеры из grep (§2 шаг 2) перечислены в шапке файла
[ ] MERGE разложен в порядке UPDATE → NOT MATCHED BY SOURCE → INSERT
[ ] источник материализован в #src (или объяснено, почему не нужно)
[ ] решение по дублям принято и записано: проверка добавлена / не нужна, потому что…
[ ] THROW / RAISERROR выбраны по правилу §4.3, а не наугад
[ ] XML-функция: plpgsql, схема web_<схема>, колонки в lower, типы как у .value()
[ ] файл функции лежит в 04_port/ported/native/, а не только в контейнере
[ ] RETURN-коды, имена и типы параметров, порядок колонок INSERT не изменены
[ ] накат на Babelfish без единого Msg
[ ] сценарий 1 (удачный путь): diff целевых таблиц пуст, RC совпал, изменения реально были
[ ] сценарий 2 (повтор): diff пуст, поведение на втором прогоне совпадает с эталоном
[ ] сценарий 3 (ошибка): RC и класс ошибки совпали либо расхождение объяснено,
    цель не изменилась ни на одном движке
[ ] в шапке проставлено «ПРОВЕРЕНО ЗАПУСКОМ: …» с датой, либо честное «НЕ ПРОВЕРЕНО»
[ ] известные непокрытые риски названы: конкурентность, производительность,
    прямые вызовы мимо процедур
```
