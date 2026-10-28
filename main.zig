const std = @import("std");
const linux = std.os.linux;

// Ambiente mínimo que passamos para os programas filhos
const envp = [_:null]?[*:0]const u8{
    "PATH=/usr/local/bin:/usr/bin:/bin",
    "TERM=xterm-256color",
};

// Pastas onde procuramos os comandos (o que o PATH faria)
const pastas_path = [_][]const u8{ "/usr/local/bin", "/usr/bin", "/bin" };

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var in_buf: [4096]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(io, &in_buf);
    const stdin = &stdin_reader.interface;

    var out_buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &out_buf);
    const stdout = &stdout_writer.interface;

    var arena_state = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_state.deinit();

    while (true) {
        _ = arena_state.reset(.retain_capacity);
        const arena = arena_state.allocator();

        try stdout.writeAll("zsh> ");
        try stdout.flush();

        const line = (stdin.takeDelimiter('\n') catch continue) orelse break;

        // Quebra em palavras
        var args: [64][]const u8 = undefined;
        var n: usize = 0;
        var it = std.mem.tokenizeAny(u8, line, " \t\r");
        while (it.next()) |tok| {
            if (n == args.len) break;
            args[n] = tok;
            n += 1;
        }
        if (n == 0) continue;
        const argv = args[0..n];

        if (std.mem.eql(u8, argv[0], "exit")) break;

        if (std.mem.eql(u8, argv[0], "cd")) {
            try cmdCd(arena, stdout, argv);
            continue;
        }

        try executar(arena, stdout, argv);
    }

    try stdout.writeAll("shell finalizado!\n");
    try stdout.flush();
}

fn executar(arena: std.mem.Allocator, stdout: *std.Io.Writer, argv: []const []const u8) !void {
    // 1) argv no formato C: strings terminadas em \0, lista terminada em null
    const argv_z = try arena.allocSentinel(?[*:0]const u8, argv.len, null);
    for (argv, 0..) |a, i| argv_z[i] = (try arena.dupeZ(u8, a)).ptr;

    // 2) Monta antes do fork os caminhos candidatos: "/usr/bin/ls", "/bin/ls"...
    var candidatos: [pastas_path.len + 1][:0]const u8 = undefined;
    var qtd: usize = 0;
    if (std.mem.indexOfScalar(u8, argv[0], '/') != null) {
        candidatos[0] = try arena.dupeZ(u8, argv[0]); // ex: ./programa
        qtd = 1;
    } else {
        for (pastas_path) |dir| {
            candidatos[qtd] = try std.fmt.allocPrintSentinel(arena, "{s}/{s}", .{ dir, argv[0] }, 0);
            qtd += 1;
        }
    }

    // Esvazia o buffer antes do fork para o texto nao sair duplicado
    try stdout.flush();

    // fork!
    const rc = linux.fork();
    if (linux.errno(rc) != .SUCCESS) {
        try stdout.writeAll("erro: fork falhou\n");
        try stdout.flush();
        return;
    }
    const pid: linux.pid_t = @intCast(rc);

    if (pid == 0) {
        // ===== FILHO =====
        // Tenta cada caminho. Se execve funcionar, não volta mais.
        for (candidatos[0..qtd]) |caminho| {
            _ = linux.execve(caminho.ptr, argv_z.ptr, &envp);
        }
        // Chegou aqui: nenhum execve funcionou
        const msg = "comando não encontrado\n";
        _ = linux.write(2, msg.ptr, msg.len);
        linux.exit(127);
    }

    // ===== PAI =====
    var status: u32 = 0;
    while (true) {
        const w = linux.wait4(pid, &status, 0, null);
        switch (linux.errno(w)) {
            .SUCCESS => break,
            .INTR => continue, // interrompido por sinal: tenta de novo
            else => {
                try stdout.writeAll("erro: wait4 falhou\n");
                try stdout.flush();
                return;
            },
        }
    }

    // 5) Decodifica o status
    if (linux.W.IFEXITED(status)) {
        const code = linux.W.EXITSTATUS(status);
        if (code != 0) try stdout.print("[saiu com código {d}]\n", .{code});
    } else if (linux.W.IFSIGNALED(status)) {
        try stdout.print("[morto pelo sinal {d}]\n", .{linux.W.TERMSIG(status)});
    }
    try stdout.flush();
}

fn cmdCd(arena: std.mem.Allocator, stdout: *std.Io.Writer, argv: []const []const u8) !void {
    if (argv.len < 2) {
        try stdout.writeAll("uso: cd <pasta>\n");
        try stdout.flush();
        return;
    }
    const path = try arena.dupeZ(u8, argv[1]);
    // syscall chdir direta, sem libc
    if (linux.errno(linux.chdir(path.ptr)) != .SUCCESS) {
        try stdout.print("cd: não consegui entrar em {s}\n", .{argv[1]});
        try stdout.flush();
    }
}