import unittest

from scripts.audit_change import funciones_sin_search_path


class AuditFunctionHeadersTests(unittest.TestCase):
    def test_comment_on_does_not_create_a_definer(self):
        sql = """
        CREATE FUNCTION public.safe() RETURNS int LANGUAGE sql
        SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$ SELECT 1 $$;
        COMMENT ON FUNCTION public.safe() IS 'Internal SECURITY DEFINER function';
        """
        self.assertEqual(funciones_sin_search_path(sql), [])

    def test_next_function_cannot_hide_missing_search_path(self):
        sql = """
        CREATE FUNCTION public.unsafe() RETURNS int LANGUAGE sql SECURITY DEFINER AS $$ SELECT 1 $$;
        CREATE FUNCTION public.safe() RETURNS int LANGUAGE sql SET search_path=public,pg_temp SECURITY DEFINER AS $$ SELECT 1 $$;
        """
        self.assertEqual(funciones_sin_search_path(sql), ["public.unsafe"])
