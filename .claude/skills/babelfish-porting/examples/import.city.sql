-- ПОРТИРОВАНО ПОД BABELFISH 5.4.0. Исходник: [import].[city], 121 строка.
-- Блокеры и что с ними сделано:
--   1) @import_subdata.nodes('/city/r') + CROSS APPLY + i.q.value(...)
--        → нативная PL/pgSQL функция web_import.shred_city(doc text),
--          вызывается из T-SQL как import.shred_city(...). Метод .nodes()/.query()
--          не поддержан ни в одной версии Babelfish.
--   2) MERGE dbo.city (MATCHED + NOT MATCHED) → UPDATE ... FROM ...; затем
--      INSERT ... WHERE NOT EXISTS. Порядок сохранён: сначала UPDATE, потом INSERT.
--   3) MERGE ponominalu.region_mapping (только NOT MATCHED) → INSERT ... WHERE NOT EXISTS.
--   4) FORMATMESSAGE(...) → обычная конкатенация с ISNULL(CONVERT(VARCHAR(20),...),'').
--   5) RAISERROR(52372,16,1) с числовым кодом → RAISERROR с текстом,
--      номер сохранён в тексте (sys.messages в Babelfish нет). RETURN-код 52372 не изменён.
-- .exist() поддержан с Babelfish 4.4.0 — оставлен как был.
-- Табличная переменная @cities_to_import оставлена без изменений — поддерживается.
CREATE PROCEDURE [import].[city]
       (
                 @import_subdata XML
       )
AS
    BEGIN
        SET NOCOUNT , ARITHABORT , XACT_ABORT ON;

        DECLARE @task_name VARCHAR(200)='[web].[import].[city]';
        DECLARE @cities_to_import TABLE
                                        (
                                        city_id   INT
                                      , name      NVARCHAR(250)
                                      , region_id INT
                                        );


        EXEC [import].[info_upsert] 
             @task_name=@task_name
           , @info=''
           , @task_xml=@import_subdata
           , @task_state='STARTED';

        IF @import_subdata.exist( '/city/r' ) = 0
            BEGIN

                EXEC [import].[info_upsert] 
                     @task_name=@task_name
                   , @info='NO DATA'
                   , @task_state='ERROR';

                -- было: RAISERROR(52372 , 16 , 1) — код сообщения из sys.messages,
                -- которой в Babelfish нет. Номер перенесён в текст.
                RAISERROR('52372: NO DATA in /city/r' , 16 , 1);
                RETURN 52372;
        END;

        BEGIN TRY
            -- было:
            --   FROM @import_subdata.nodes('/city/r') AS I(Q)
            --        CROSS APPLY (SELECT i.q.value('@basis_city_id','int') ...) AS x
            -- CONVERT(NVARCHAR(250), x.name) повторяет усечение,
            -- которое в MS SQL делал .value('@name','nvarchar(250)').
            INSERT INTO @cities_to_import(
                   city_id
                 , name
                 , region_id
                            )
            SELECT 
                   x.[city_id]
                 , CONVERT(NVARCHAR(250), x.[name])
                 , x.region_id
            FROM 
                 import.shred_city( CONVERT(VARCHAR(MAX), @import_subdata) ) AS x;

            -- было: MERGE dbo.city AS t USING @cities_to_import s ON t.city_id = s.city_id
            --       WHEN MATCHED AND (name/region_id отличаются) THEN UPDATE
            --       WHEN NOT MATCHED THEN INSERT
            -- Ветка MATCHED: те же условие соединения и предикат отличия.
            UPDATE t
               SET t.[name]    = s.[name]
                 , t.region_id = s.region_id
              FROM dbo.city AS t
             INNER JOIN @cities_to_import AS s ON t.city_id = s.city_id
             WHERE t.[name] <> s.[name]
                OR t.region_id <> s.region_id;

            -- Ветка NOT MATCHED. Порядок колонок INSERT сохранён как в оригинале.
            INSERT INTO dbo.city (
                   city_id
                 , region_id
                 , [name])
            SELECT 
                   s.city_id
                 , s.region_id
                 , s.[name]
              FROM @cities_to_import AS s
             WHERE NOT EXISTS (
                   SELECT 1
                     FROM dbo.city AS t
                    WHERE t.city_id = s.city_id );

            -- было: MERGE ponominalu.region_mapping AS prm USING @cities_to_import s
            --       ON prm.city_id = s.city_id WHEN NOT MATCHED THEN INSERT
            -- Ветка одна, эквивалент — INSERT с проверкой отсутствия.
            INSERT INTO ponominalu.region_mapping (
                   city_id
                 , pn_region_id)
            SELECT 
                   s.city_id
                 , s.city_id
              FROM @cities_to_import AS s
             WHERE NOT EXISTS (
                   SELECT 1
                     FROM ponominalu.region_mapping AS prm
                    WHERE prm.city_id = s.city_id );
        END TRY
        BEGIN CATCH
            IF @@TRANCOUNT > 0
                ROLLBACK TRANSACTION;
            DECLARE @ERROR_PROCEDURE VARCHAR(256)=ERROR_PROCEDURE();
            DECLARE @ERROR_NUMBER INT=ERROR_NUMBER();
            DECLARE @ERROR_MESSAGE VARCHAR(2000)=ERROR_MESSAGE();
            DECLARE @ERROR_LINE INT=ERROR_LINE();
            DECLARE @MSG VARCHAR(2000);
            -- было: FORMATMESSAGE('ERROR_NUMBER = %d, ...', ...) — в Babelfish не поддержана
            SELECT 
                   @MSG = 'ERROR_NUMBER = ' + ISNULL(CONVERT(VARCHAR(20),@ERROR_NUMBER),'')
                        + ', ERROR_MESSAGE = ' + ISNULL(@ERROR_MESSAGE,'')
                        + ', ERROR_PROCEDURE = ' + ISNULL(@ERROR_PROCEDURE,'')
                        + ', ERROR_LINE = ' + ISNULL(CONVERT(VARCHAR(20),@ERROR_LINE),'');

            EXEC [import].[info_upsert] 
                 @task_name=@task_name
               , @info=@MSG
               , @task_state='ERROR';


            RAISERROR(@MSG , 16 , 1);
            RETURN @ERROR_NUMBER;
        END CATCH;




        EXEC [import].[info_upsert] 
             @task_name=@task_name
           , @info=''
           , @task_state='SUCCESS';
        RETURN 0;

    END
