import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { isValidCallbackToken } from "./verify_token.ts";

Deno.test("accepts a matching token", () => {
  assertEquals(isValidCallbackToken("secret123", "secret123"), true);
});

Deno.test("rejects a non-matching token", () => {
  assertEquals(isValidCallbackToken("wrong", "secret123"), false);
});

Deno.test("rejects a null token", () => {
  assertEquals(isValidCallbackToken(null, "secret123"), false);
});

Deno.test("rejects a token of different length", () => {
  assertEquals(isValidCallbackToken("secret12", "secret123"), false);
});
