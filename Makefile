.PHONY: all build package test verify clean
all: package
build:
	python3 scripts/build.py
package:
	python3 scripts/build.py --package
	python3 scripts/verify_package.py
verify:
	python3 scripts/verify_package.py
test:
	python3 -m unittest discover -s tests -p 'test_*.py' -v
	bash tests/run-daemon-tests.sh
	bash tests/run-helper-tests.sh
	bash tests/run-oauth-store-tests.sh
	bash tests/run-authorization-attempt-tests.sh
	bash tests/run-oauth-request-tests.sh
	bash tests/run-diagnostics-tests.sh
clean:
	python3 -c 'import shutil; shutil.rmtree("build", ignore_errors=True)'
