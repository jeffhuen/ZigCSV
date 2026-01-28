alias ZigCSV.RFC4180, as: Zig
alias NimbleCSV.RFC4180, as: Nimble

# Generate test data
csv = 1..10_000
|> Enum.map(fn i -> "#{i},user#{i},value#{i}" end)
|> Enum.join("\n")
|> then(fn data -> "id,name,value\n" <> data <> "\n" end)

File.write!("/tmp/compat_test.csv", csv)

IO.puts("=== Streaming Compatibility Check ===")

# Test streaming compatibility
{zig_time, zig_count} = :timer.tc(fn ->
  File.stream!("/tmp/compat_test.csv", [], 64 * 1024)
  |> Zig.parse_stream(skip_headers: true)
  |> Enum.count()
end)

{nimble_time, nimble_count} = :timer.tc(fn ->
  File.stream!("/tmp/compat_test.csv")
  |> Nimble.parse_stream(skip_headers: true)
  |> Enum.count()
end)

IO.puts("ZigCSV:    #{zig_count} rows in #{div(zig_time, 1000)}ms")
IO.puts("NimbleCSV: #{nimble_count} rows in #{div(nimble_time, 1000)}ms")
IO.puts("Row count match: #{zig_count == nimble_count}")

# Test line-based (fair comparison)
IO.puts("")
IO.puts("=== Line-based Streaming (Fair Comparison) ===")

zig_line_rows = File.stream!("/tmp/compat_test.csv")
                |> Zig.parse_stream(skip_headers: true)
                |> Enum.take(5)

nimble_rows = File.stream!("/tmp/compat_test.csv")
              |> Nimble.parse_stream(skip_headers: true)
              |> Enum.take(5)

IO.puts("Line-based first 5 match: #{zig_line_rows == nimble_rows}")
IO.puts("ZigCSV:    #{inspect(zig_line_rows)}")
IO.puts("NimbleCSV: #{inspect(nimble_rows)}")

# Test binary chunks (ZigCSV unique capability)
IO.puts("")
IO.puts("=== Binary Chunk Streaming (ZigCSV only) ===")

zig_chunk_rows = File.stream!("/tmp/compat_test.csv", [], 64 * 1024)
                 |> Zig.parse_stream(skip_headers: true)
                 |> Enum.take(5)

IO.puts("ZigCSV chunk first 5: #{inspect(zig_chunk_rows)}")

File.rm!("/tmp/compat_test.csv")
