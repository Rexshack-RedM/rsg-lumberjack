fx_version 'cerulean'
rdr3_warning 'I acknowledge that this is a prerelease build of RedM, and I am aware my resources *will* become incompatible once RedM ships.'
game 'rdr3'

name 'rsg-lumberjack'
description 'Lumberjack gameplay: grow, chop, carry, and sell wagon loads of logs'
version '2.0.0'

shared_scripts {
    '@ox_lib/init.lua',
    'shared/config.lua',
}

server_scripts {
    'server/db.lua',
    'server/main.lua',
    'server/versionchecker.lua'
}

client_scripts {
    'client/main.lua'
}

dependencies {
    'rsg-core',
    'ox_lib',
    'rsg-target',
    'rsg-inventory',
    'oxmysql',
}

files {
    'locales/*.json'
}

lua54 'yes'
