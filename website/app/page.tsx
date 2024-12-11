import Image from "next/image";

export default function Home() {
  return (
    <main className="flex min-h-screen flex-col items-center justify-between p-24">
      <div className="z-10 max-w-5xl w-full items-center justify-between font-mono text-sm lg:flex"></div>

      <div className="relative flex place-items-center before:absolute before:h-[300px] before:w-[480px] before:-translate-x-1/2 before:rounded-full after:absolute after:-z-20 after:h-[180px] after:w-[240px] after:translate-x-1/3 after:content-[''] before:lg:h-[360px] z-[-1]">
        <p className="text-9xl">
          <Image
            src="/icon-new.png"
            alt="Ghostty Icon"
            width={250}
            height={250}
            priority
          />
        </p>
      </div>

      <div className="mb-32 grid text-center lg:max-w-5xl lg:w-full lg:mb-0 lg:grid-cols-4 lg:text-left"></div>
    </main>
  );
}
