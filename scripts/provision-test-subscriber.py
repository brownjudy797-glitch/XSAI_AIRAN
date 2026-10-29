#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Validate the audited legacy OAI users schema and add one NEW test subscriber."""
import argparse
import getpass
import re
import secrets
import subprocess
import sys

REQUIRED = {'imsi','mmeidentity_idmmeidentity','key','sqn','rand','OPc'}

def mysql(sql):
    result = subprocess.run(['sudo','-n','mysql','--batch','--skip-column-names','oai_db'],
                            input=sql,text=True,capture_output=True)
    if result.returncode:
        code = re.search(r'ERROR\s+(\d+)', result.stderr)
        raise ValueError('MySQL command failed' + (' (error '+code[1]+')' if code else '') +
                         '; inspect local service/schema/permissions. SQL and keys are intentionally not printed.')
    return result.stdout

def check_schema():
    columns = {line.split('\t')[0] for line in mysql('SHOW COLUMNS FROM users;\n').splitlines()}
    if not REQUIRED.issubset(columns):
        raise ValueError('Database schema differs from the audited users table; do not guess an INSERT statement.')

def statement(imsi, key, opc, sqn, random_hex):
    if not re.fullmatch(r'\d{15}',imsi): raise ValueError('IMSI must have 15 decimal digits.')
    for name, value in [('K',key),('OPc',opc),('RAND',random_hex)]:
        if not re.fullmatch(r'[0-9a-fA-F]{32}',value): raise ValueError(name+' must be 16 bytes / 32 hex digits.')
    if not 0 <= sqn < 2**48: raise ValueError('SQN must be an unsigned 48-bit counter.')
    return ("INSERT INTO users (`imsi`,`mmeidentity_idmmeidentity`,`key`,`sqn`,`rand`,`OPc`) "
            f"VALUES ('{imsi}',0,UNHEX('{key}'),{sqn},UNHEX('{random_hex}'),UNHEX('{opc}'));\n")

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action',choices=['check','add'])
    parser.add_argument('--apply',action='store_true')
    args=parser.parse_args()
    check_schema()
    if args.action=='check':
        print('Audited users schema found. Subscriber values were not read or changed.'); return
    if not args.apply:
        print('No subscriber changed. To add a new test USIM interactively, use: add --apply'); return
    imsi=input('Test USIM IMSI (15 digits): ').strip()
    if not re.fullmatch(r'\d{15}',imsi): raise ValueError('Invalid IMSI.')
    if int(mysql(f"SELECT COUNT(*) FROM users WHERE imsi='{imsi}';\n").strip()):
        raise ValueError('IMSI already exists. Refusing to overwrite keys or reset SQN.')
    key=getpass.getpass('Test USIM K (32 hex digits; hidden): ').strip()
    opc=getpass.getpass('Test USIM OPc, not OP (32 hex digits; hidden): ').strip()
    value=input('Initial SQN as decimal, matching this NEW test USIM [0]: ').strip() or '0'
    if not value.isdigit(): raise ValueError('SQN must be decimal.')
    sql=statement(imsi,key,opc,int(value),secrets.token_hex(16))
    mysql(sql)
    print('New subscriber inserted. Match PLMN/DNN and USIM settings locally before registration testing.')

if __name__=='__main__':
    try: main()
    except (OSError,ValueError) as error:
        print('ERROR: '+str(error),file=sys.stderr);sys.exit(1)
