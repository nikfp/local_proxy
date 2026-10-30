defmodule LocalProxy.ConfigTest do
  use ExUnit.Case, async: true

  alias LocalProxy.Config

  describe "parse_port/2" do
    test "defaults to 4000 for outbound and 4001 for inbound when unset" do
      assert Config.parse_port(nil) == {:ok, 4000}
      assert Config.parse_port(nil, 4001) == {:ok, 4001}
    end

    test "accepts valid ports" do
      assert Config.parse_port("1") == {:ok, 1}
      assert Config.parse_port("8080") == {:ok, 8080}
      assert Config.parse_port("65535") == {:ok, 65_535}
    end

    test "rejects non-numeric and out-of-range values" do
      assert {:error, _} = Config.parse_port("")
      assert {:error, _} = Config.parse_port("not-a-port")
      assert {:error, _} = Config.parse_port("0")
      assert {:error, _} = Config.parse_port("65536")
      assert {:error, _} = Config.parse_port("80.5")
    end

    test "parse_port!/3 raises with the variable name" do
      error =
        assert_raise RuntimeError, fn ->
          Config.parse_port!("nope", 4000, "OUTBOUND_PORT")
        end

      assert error.message =~ "OUTBOUND_PORT"
    end

    test "rejects identical listener ports" do
      error = assert_raise RuntimeError, fn -> Config.ensure_distinct_ports!(4000, 4000) end
      assert error.message =~ "must differ"

      assert Config.ensure_distinct_ports!(4000, 4001) == :ok
    end
  end

  describe "decode_cloak_key/1" do
    test "decodes a 32-byte base64 key" do
      encoded = Base.encode64(:binary.copy(<<1>>, 32))
      assert {:ok, key} = Config.decode_cloak_key(encoded)
      assert byte_size(key) == 32
    end

    test "rejects missing, invalid, and wrong-length keys" do
      assert {:error, message} = Config.decode_cloak_key(nil)
      assert message =~ "missing"

      assert {:error, message} = Config.decode_cloak_key("not base64!")
      assert message =~ "base64"

      assert {:error, message} = Config.decode_cloak_key(Base.encode64("short"))
      assert message =~ "32 bytes"
    end
  end

  describe "parse_positive_integer/2" do
    test "uses the default and accepts positive values" do
      assert Config.parse_positive_integer(nil, 10) == {:ok, 10}
      assert Config.parse_positive_integer("25", 10) == {:ok, 25}
    end

    test "rejects zero and negatives" do
      assert {:error, _} = Config.parse_positive_integer("0", 10)
      assert {:error, _} = Config.parse_positive_integer("-1", 10)
    end
  end
end
