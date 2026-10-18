.PHONY: up demo down

up:
	./deploy/setup.sh

demo: up
	./hack/demo.sh

down:
	./deploy/teardown.sh
