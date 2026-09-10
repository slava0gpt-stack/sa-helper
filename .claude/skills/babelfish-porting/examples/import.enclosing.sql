-- ПОРТИРОВАНО ПОД BABELFISH. Исходник: [import].[enclosing], 109 строк.
-- Четыре блокера и что с ними сделано:
--   1) @xml.nodes()+CROSS APPLY+.value() → нативная PL/pgSQL функция import.shred_enclosing
--   2) MERGE (только ветка WHEN NOT MATCHED) → INSERT ... WHERE NOT EXISTS
--   3) FORMATMESSAGE() → обычная конкатенация
--   4) RAISERROR(52372,...) с кодом → RAISERROR с текстом (sys.messages в Babelfish нет)
CREATE PROCEDURE [import].[enclosing]
                 @import_subdata  XML
               , @is_force_import BIT=0
AS
    BEGIN
        SET NOCOUNT , ARITHABORT , XACT_ABORT ON;

        DECLARE @task_name VARCHAR(200)='[web].[import].[enclosing]';

        EXEC [import].[info_upsert]
             @task_name=@task_name, @info='', @task_xml=@import_subdata, @task_state='STARTED';

        -- .exist() поддерживается с Babelfish 4.4.0 — оставляем как было
        IF @import_subdata.exist( '/enclosing/r' ) = 0
        AND @is_force_import = 0
            BEGIN
                EXEC [import].[info_upsert]
                     @task_name=@task_name, @info='NO DATA', @task_state='ERROR';
                -- было: RAISERROR(52372, 16, 1) — код из sys.messages, которого в Babelfish нет
                RAISERROR('52372: NO DATA in /enclosing/r' , 16 , 1);
                RETURN 52372;
        END;

        DROP TABLE IF EXISTS #enclosing;

        -- было: FROM @import_subdata.nodes('/enclosing/r') AS I(Q) CROSS APPLY (... .value() ...)
        SELECT basis_hall_id , basis_section_id
          INTO #enclosing
          FROM import.shred_enclosing( CONVERT(VARCHAR(MAX), @import_subdata) );

        BEGIN TRY
            -- было: MERGE ... WHEN NOT MATCHED THEN INSERT.
            -- Ветка была одна, поэтому эквивалент — INSERT с проверкой отсутствия.
            INSERT INTO dbo.enclosing (hall_id , section_id)
            SELECT s.hall_id , s.section_id
              FROM (
                    SELECT ho.obj_id AS hall_id , e.[basis_section_id] AS section_id
                      FROM #enclosing AS e
                     INNER JOIN dbo.obj AS ho ON ho.basis_id = e.basis_hall_id
                     INNER JOIN dbo.obj_type AS hot ON hot.code = 'hall'
                                                   AND hot.obj_type_id = ho.obj_type_id
                   ) AS s
             WHERE NOT EXISTS (
                    SELECT 1 FROM dbo.enclosing AS t
                     WHERE t.hall_id = s.hall_id AND t.section_id = s.section_id );
        END TRY
        BEGIN CATCH
            IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
            DECLARE @ERROR_PROCEDURE VARCHAR(256)=ERROR_PROCEDURE();
            DECLARE @ERROR_NUMBER INT=ERROR_NUMBER();
            DECLARE @ERROR_MESSAGE VARCHAR(2000)=ERROR_MESSAGE();
            DECLARE @ERROR_LINE INT=ERROR_LINE();
            DECLARE @MSG VARCHAR(2000);
            -- было: FORMATMESSAGE('... %d ... %s ...', ...) — в Babelfish не поддержана
            SET @MSG = 'ERROR_NUMBER = ' + ISNULL(CONVERT(VARCHAR(20),@ERROR_NUMBER),'')
                     + ', ERROR_MESSAGE = ' + ISNULL(@ERROR_MESSAGE,'')
                     + ', ERROR_PROCEDURE = ' + ISNULL(@ERROR_PROCEDURE,'')
                     + ', ERROR_LINE = ' + ISNULL(CONVERT(VARCHAR(20),@ERROR_LINE),'');

            EXEC [import].[info_upsert]
                 @task_name=@task_name, @info=@MSG, @task_state='ERROR';

            RAISERROR(@MSG , 16 , 1);
            RETURN @ERROR_NUMBER;
        END CATCH;

        EXEC [import].[info_upsert]
             @task_name=@task_name, @info='', @task_state='SUCCESS';
        RETURN 0;
    END
