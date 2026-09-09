# PostgreSQL guard tests

The regular `mix test` suite uses ETS. PostgreSQL tests run when
`ASH_RA_POSTGRES_PORT` is set and require a disposable local database named
`guard_test`, with user `postgres` and password `guard-test`.

For example, start an isolated database (no mounted volumes):

```sh
docker run -d --rm --name ash-ra-guard-test \
  -e POSTGRES_PASSWORD=guard-test -e POSTGRES_DB=guard_test \
  -p 127.0.0.1::5432 postgres:17.2
docker port ash-ra-guard-test 5432
```

Use the printed port after PostgreSQL is ready:

```sh
ASH_RA_POSTGRES_PORT=PORT mix test
docker stop ash-ra-guard-test
```

The suite creates `guard_test_targets` and `guard_test_sources` tables, an insert
trigger for testing database-generated keys, and a distinct tenant for each test.
Stopping the example container removes its
temporary database. Never point these tests at an application database.
