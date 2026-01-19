# -*- coding: utf-8 -*-
"""
MDesk 버전 업그레이드 스크립트
"""
import re
import sys
import os
from datetime import datetime

def get_current_version():
    """현재 버전 읽기"""
    try:
        with open('src/version.rs', 'r', encoding='utf-8') as f:
            content = f.read()
        match = re.search(r'VERSION: &str = "([^"]+)"', content)
        if match:
            return match.group(1)
    except:
        pass
    return "unknown"

def update_version(new_version, build_num):
    """버전 업데이트"""
    build_date = datetime.now().strftime("%Y-%m-%d %H:%M")
    
    print()
    print("버전 업그레이드 중...")
    print()
    
    # 1. src/version.rs 수정
    try:
        with open('src/version.rs', 'r', encoding='utf-8') as f:
            content = f.read()
        content = re.sub(r'VERSION: &str = "[^"]+"', f'VERSION: &str = "{new_version}"', content)
        content = re.sub(r'BUILD_DATE: &str = "[^"]+"', f'BUILD_DATE: &str = "{build_date}"', content)
        with open('src/version.rs', 'w', encoding='utf-8') as f:
            f.write(content)
        print('  [OK] src/version.rs')
    except Exception as e:
        print(f'  [ERROR] src/version.rs: {e}')
        return False

    # 2. Cargo.toml 수정
    try:
        with open('Cargo.toml', 'r', encoding='utf-8') as f:
            lines = f.readlines()
        for i, line in enumerate(lines):
            if line.startswith('version = '):
                lines[i] = f'version = "{new_version}"\n'
                break
        with open('Cargo.toml', 'w', encoding='utf-8') as f:
            f.writelines(lines)
        print('  [OK] Cargo.toml')
    except Exception as e:
        print(f'  [ERROR] Cargo.toml: {e}')
        return False

    # 3. flutter/pubspec.yaml 수정
    try:
        with open('flutter/pubspec.yaml', 'r', encoding='utf-8') as f:
            content = f.read()
        content = re.sub(r'^version: .+$', f'version: {new_version}+{build_num}', content, flags=re.MULTILINE)
        with open('flutter/pubspec.yaml', 'w', encoding='utf-8') as f:
            f.write(content)
        print('  [OK] flutter/pubspec.yaml')
    except Exception as e:
        print(f'  [ERROR] flutter/pubspec.yaml: {e}')
        return False

    # 4. libs/portable/Cargo.toml 수정
    try:
        with open('libs/portable/Cargo.toml', 'r', encoding='utf-8') as f:
            lines = f.readlines()
        for i, line in enumerate(lines):
            if line.startswith('version = '):
                lines[i] = f'version = "{new_version}"\n'
                break
        with open('libs/portable/Cargo.toml', 'w', encoding='utf-8') as f:
            f.writelines(lines)
        print('  [OK] libs/portable/Cargo.toml')
    except Exception as e:
        print(f'  [ERROR] libs/portable/Cargo.toml: {e}')
        return False

    print()
    print("============================================")
    print("버전 업그레이드 완료!")
    print("============================================")
    print(f"  버전: {new_version}")
    print(f"  빌드 번호: {build_num}")
    print(f"  빌드 날짜: {build_date}")
    print()
    print("빌드를 진행하려면 build_windows.bat을 실행하세요.")
    return True

def main():
    print("============================================")
    print("  MDesk 버전 업그레이드 스크립트")
    print("============================================")
    print()
    
    current_version = get_current_version()
    print(f"현재 버전: {current_version}")
    print()
    
    # 새 버전 입력
    new_version = input("새 버전을 입력하세요 (엔터 = 현재 버전 유지): ").strip()
    if not new_version:
        new_version = current_version
        print(f"버전 유지: {current_version}")
    else:
        print(f"새 버전: {new_version}")
    
    # 빌드 번호 입력
    print()
    build_num = input("빌드 번호를 입력하세요 (엔터 = 1): ").strip()
    if not build_num:
        build_num = "1"
    
    # 확인
    print()
    print("============================================")
    print("적용할 변경사항:")
    print("============================================")
    print(f"버전: {new_version}")
    print(f"빌드 번호: {build_num}")
    print()
    print("대상 파일:")
    print("  - src/version.rs")
    print("  - Cargo.toml")
    print("  - flutter/pubspec.yaml")
    print("  - libs/portable/Cargo.toml")
    print("============================================")
    print()
    
    confirm = input("진행하시겠습니까? (Y/N): ").strip().upper()
    if confirm != 'Y':
        print("취소되었습니다.")
        return
    
    update_version(new_version, build_num)

if __name__ == "__main__":
    main()


