<?php

$identity = $argv[1] ?? '';
$password = $argv[2] ?? '';
$configPath = $argv[3] ?? '';

if (!$identity || !$password || !$configPath || !file_exists($configPath)) {
    fwrite(STDOUT, json_encode(["success" => false]));
    exit(0);
}

include $configPath;

$pdo = new PDO(
    "mysql:host={$db_host};dbname={$db_name};charset=utf8mb4",
    $db_username,
    $db_password,
    [
        PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
        PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
    ]
);

$stmt = $pdo->prepare(
    "SELECT a.id, a.username, a.email, a.disabled, a.roleid, a.authmodule, a.password, a.passwordhash, r.name AS role_name
     FROM tbladmins a
     LEFT JOIN tbladminroles r ON r.id = a.roleid
     WHERE (LOWER(a.username) = LOWER(?) OR LOWER(a.email) = LOWER(?))
     LIMIT 1"
);
$stmt->execute([$identity, $identity]);
$row = $stmt->fetch();

if (!$row || (int) ($row['disabled'] ?? 0) === 1) {
    fwrite(STDOUT, json_encode(["success" => false]));
    exit(0);
}

$hashes = array_values(array_filter([
    $row['password'] ?? '',
    $row['passwordhash'] ?? '',
]));

$valid = false;
foreach ($hashes as $hash) {
    if ($hash && password_verify($password, $hash)) {
        $valid = true;
        break;
    }
}

if (!$valid) {
    fwrite(STDOUT, json_encode(["success" => false]));
    exit(0);
}

fwrite(STDOUT, json_encode([
    "success" => true,
    "admin" => [
        "id" => $row["id"],
        "username" => $row["username"],
        "email" => $row["email"],
        "roleId" => $row["roleid"],
        "roleName" => $row["role_name"] ?? null,
    ],
]));
